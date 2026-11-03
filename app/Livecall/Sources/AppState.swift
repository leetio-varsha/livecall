import SwiftUI
import AppKit

/// Mirrors `TrackHealth` in core/src/engine.ts.
enum TrackHealth: String {
    /// Never delivered a frame — capture never started (or hasn't yet).
    case off
    /// Frames are arriving.
    case live
    /// Frames stopped arriving. Audio frames flow through silence too, so this
    /// never means "nobody is talking" — it means the capture died.
    case stalled
}

/// Everything the menu bar and the panel show, plus the wiring between capture
/// (in this process, so the TCC grants land on the signed app) and the Node
/// core (a child process driven over the frame protocol).
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var status = "Starting…"
    @Published var running = false
    @Published var answering = false
    /// Every answer this run, oldest first, restored from disk at boot. The
    /// panel shows one at a time; `answer` below is whichever that is.
    @Published private(set) var history: [AnswerRecord] = []
    /// Index into `history` of the record on screen. Snaps to the newest
    /// whenever an answer starts — you pressed the hotkey to see THAT one.
    @Published private(set) var viewing = 0
    @Published var lastHeard = ""
    @Published var micOn = false
    @Published var systemOn = false
    @Published var hotkeysOn = false
    /// Whether each track is actually DELIVERING audio, as opposed to having
    /// started successfully once. Those are different facts, and only this one
    /// predicts whether the next hotkey press will have anything to answer.
    @Published var micLive: TrackHealth = .off
    @Published var systemLive: TrackHealth = .off
    /// True while capture is being rebuilt after a stall.
    @Published var recovering = false
    /// One line in the panel about something happening RIGHT NOW ("taking
    /// the screen…") or something that just failed. Cleared when the next answer
    /// starts, because by then it is either irrelevant or visible in the answer.
    @Published var notice: String?
    /// Spend readout for the menu ("$0.004 · today $1.87 (23 calls)").
    @Published var spendLine = ""
    @Published var telegramOn = false
    @Published var lastDelivery = ""

    let repoRoot = BuildConfig.repoRoot
    /// Cap on pasted/attached context — it rides along on every hotkey press.
    private(set) var contextMaxChars = 60_000
    /// Input price per 1M tokens for the configured model, for the cost readout.
    private(set) var inputRatePer1M = 5.0
    /// Cache-write multiplier over input: 2x for the 1-hour cache (default),
    /// 1.25x for the 5-minute one — mirrors core/src/pricing.ts.
    private(set) var cacheWritePremium = 2.0
    private(set) var hotkeyFastLabel = "⌥⌘A"
    private(set) var hotkeyDeepLabel = "⌥⇧⌘A"
    private(set) var hotkeyScreenLabel = "left ⌥ tap"

    private let history_ = AnswerHistoryStore()
    /// How many answers stay in memory. A three-hour call would otherwise grow
    /// an unbounded array behind a panel that has to stay instant; the log on
    /// disk keeps everything.
    private let historyCap = 40
    /// The next answer opens a new call, so the panel marks it.
    private var nextStartsCall = true

    private let core = CoreProcess()
    private var mic: MicCapture?
    private var system: SystemAudioCapture?
    private var detector: CallDetector?
    private var hotkeys: HotkeyTap?
    private var lastCaptureRestart = Date.distantPast
    private(set) var captureRestarts = 0
    private var env: [String: String] = [:]

    /// Saved projects (named lists of context files) and which one is armed.
    @Published private(set) var projects: [Project] = []
    @Published private(set) var activeProject: String?
    private let projectStore = ProjectStore()
    /// Status line prepared at send time, shown when the core acks receipt.
    private var pendingProjectLine: String?
    /// Silent: no panel, answers go to Telegram only.
    @Published var silent = false
    lazy var panel = AnswerPanel(state: self)

    /// A copilot feeds you your line — hence a quote bubble, filled while an
    /// answer is streaming. Deliberately NOT a waveform: dictation apps own that
    /// shape in the menu bar, and two identical icons are indistinguishable at 18pt.
    var menuIcon: String {
        if answering { return silent ? "bell.slash.fill" : "quote.bubble.fill" }
        if !running { return "exclamationmark.bubble" }
        // Silent gets its own shape: the whole point is that nothing appears on
        // screen, so the menu bar is the only place the state is visible.
        return silent ? "bell.slash" : "quote.bubble"
    }

    // MARK: - The answer on screen

    var current: AnswerRecord? { history.indices.contains(viewing) ? history[viewing] : nil }
    var answer: String { current?.text ?? "" }
    var answerHeader: String { current?.header ?? "no answer yet" }
    /// True while the panel shows something older than the newest answer. The
    /// panel says so loudly: reading a stale answer out loud, believing it is
    /// the one just asked for, is the one mistake this feature could cause.
    var viewingHistory: Bool { !history.isEmpty && viewing < history.count - 1 }
    /// How many answers back the panel currently is.
    var stepsBack: Int { max(0, history.count - 1 - viewing) }
    var canShowOlder: Bool { viewing > 0 }
    var canShowNewer: Bool { viewing + 1 < history.count }

    func showOlder() { if canShowOlder { viewing -= 1 } }
    func showNewer() { if canShowNewer { viewing += 1 } }
    func showNewest() { viewing = max(0, history.count - 1) }

    /// Wipe both the panel's history and the log on disk. Offered in the menu
    /// because that log is a transcript of real answers on real calls.
    func clearHistory() {
        history.removeAll()
        viewing = 0
        history_.clear()
    }

    /// Fill the panel for `--panel-selftest --hold`, so the layout (and now the
    /// history paging) can be eyeballed and screenshot without waiting for a
    /// real call to produce three answers.
    func seedPreview(_ answers: [(question: String, header: String, text: String, startsCall: Bool)]) {
        history = answers.map {
            var rec = AnswerRecord(
                mode: "fast", question: $0.question, header: $0.header, startsCall: $0.startsCall)
            rec.text = $0.text
            return rec
        }
        viewing = max(0, history.count - 1)
    }

    /// Start the record the incoming answer streams into.
    ///
    /// `withShot` only shapes the header, deliberately: the header is what gets
    /// persisted, so history shows which answers were about the screen without
    /// adding a field that older history files wouldn't decode.
    /// `question` overrides the transcript-derived one — for a TYPED ask the
    /// typed text is the question; the last transcript segment is just noise.
    private func beginAnswer(mode: String, withShot: Bool = false, question: String? = nil) {
        let rec = AnswerRecord(
            mode: mode,
            question: question ?? lastHeard,
            header: "\(mode == "deep" ? "DEEP" : "FAST")\(withShot ? " · screen" : "") · thinking…",
            startsCall: nextStartsCall)
        nextStartsCall = false
        history.append(rec)
        if history.count > historyCap { history.removeFirst(history.count - historyCap) }
        viewing = history.count - 1
    }

    /// Edit the answer being streamed — always the newest, never whatever the
    /// user happens to have paged back to mid-stream.
    private func withLive(_ change: (inout AnswerRecord) -> Void) {
        guard !history.isEmpty else { return }
        change(&history[history.count - 1])
    }

    private func persistLive() {
        if let last = history.last { history_.append(last) }
    }

    func boot() {
        // Writing to a dead core must not kill the app.
        signal(SIGPIPE, SIG_IGN)
        // Answers from earlier runs are worth having in the panel, but this run
        // is a new call whatever they were.
        history = history_.load(limit: historyCap)
        viewing = max(0, history.count - 1)
        projects = projectStore.projects
        activeProject = projectStore.activeName
        env = EnvFile.load("\(repoRoot)/core/.env")
        silent = env["SILENT_MODE"] == "1"
        if let cap = Int(env["CONTEXT_MAX_CHARS"] ?? ""), cap > 0 { contextMaxChars = cap }
        inputRatePer1M = Self.inputRate(for: env["LLM_MODEL"] ?? "claude-opus-5")
        cacheWritePremium = env["CACHE_TTL"] == "5m" ? 1.25 : 2.0

        core.onEvent = { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        core.onLog = { NSLog("[core] %@", $0) }
        core.onExit = { [weak self] code in
            Task { @MainActor in
                self?.running = false
                self?.status = "Core exited (\(code)) — quit and relaunch"
            }
        }

        do {
            try core.start(repoRoot: repoRoot)
            status = "Loading the speech model…"
        } catch {
            status = error.localizedDescription
        }
    }

    /// Capture starts only once the core is ready to receive frames.
    private func startCapture() {
        Task {
            if await AVPermissions.requestMic() {
                do {
                    let m = MicCapture()
                    try await m.start()
                    mic = m
                    micOn = true
                } catch {
                    NSLog("mic failed: %@", error.localizedDescription)
                }
            }

            do {
                let s = SystemAudioCapture()
                try await s.start()
                system = s
                systemOn = true
            } catch {
                NSLog("system audio failed: %@", error.localizedDescription)
            }

            let det = CallDetector()
            if let extra = env["DETECT_EXCLUDE"], !extra.isEmpty {
                det.exclude(extra.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
            }
            det.onCallStart = { [weak self] in
                FrameWriter.shared.writeControl("call_start")
                // Re-read the armed project's files the moment a call begins:
                // packs are edited right up to the call, and this is the last
                // moment the fresh version can still make the first answer.
                Task { @MainActor in
                    if self?.activeProject != nil { self?.sendProjectContext() }
                }
            }
            det.onCallEnd = { FrameWriter.shared.writeControl("call_end") }
            det.start()
            detector = det

            startHotkeys()
            running = micOn || systemOn
            status = statusLine()
        }
    }

    /// Rebuild capture after the watchdog saw the frames stop.
    ///
    /// AVAudioEngine and ScreenCaptureKit both go quiet across a sleep/wake or
    /// an audio-device change without reporting anything, and the only cure is
    /// a fresh object. The floor between attempts is load-bearing: a rebuild
    /// takes a moment and the watchdog keeps reporting `stalled` until frames
    /// come back, so without it this becomes a restart loop.
    private func recoverCapture() {
        guard !recovering, Date().timeIntervalSince(lastCaptureRestart) > 15 else { return }
        lastCaptureRestart = Date()
        captureRestarts += 1
        recovering = true
        let rebuildMic = micLive == .stalled
        let rebuildSystem = systemLive == .stalled
        NSLog("capture stalled (mic=%@ system=%@) — rebuilding, attempt %d",
              micLive.rawValue, systemLive.rawValue, captureRestarts)
        status = statusLine()

        Task {
            if rebuildMic {
                mic?.stop()
                mic = nil
                do {
                    let m = MicCapture()
                    try await m.start()
                    mic = m
                    micOn = true
                } catch {
                    micOn = false
                    NSLog("mic rebuild failed: %@", error.localizedDescription)
                }
            }
            if rebuildSystem {
                await system?.stop()
                system = nil
                do {
                    let s = SystemAudioCapture()
                    try await s.start()
                    system = s
                    systemOn = true
                } catch {
                    systemOn = false
                    NSLog("system audio rebuild failed: %@", error.localizedDescription)
                }
            }
            recovering = false
            status = statusLine()
        }
    }

    private func startHotkeys() {
        guard env["HOTKEY_ENABLED"] != "0" else { return }
        let parsed = HotkeySpecs.parse([
            (mode: "fast", spec: env["HOTKEY_FAST"] ?? "ropt"),
            (mode: "deep", spec: env["HOTKEY_DEEP"] ?? "shift+ropt"),
            (mode: "screen", spec: env["HOTKEY_SCREEN"] ?? "lopt"),
        ])
        for bad in parsed.bad { NSLog("bad hotkey spec %@ — that hotkey is off", bad) }
        guard !parsed.isEmpty else { return }
        if let fast = parsed.label(for: "fast") { hotkeyFastLabel = fast }
        if let deep = parsed.label(for: "deep") { hotkeyDeepLabel = deep }
        if let screen = parsed.label(for: "screen") { hotkeyScreenLabel = screen }

        let tap = HotkeyTap(combos: parsed.combos, taps: parsed.taps) { [weak self] mode in
            // The screen question can't go straight out: there is a picture to
            // take first, and that is async.
            guard mode != "screen" else {
                Task { @MainActor in self?.askScreen() }
                return
            }
            // Straight into the core, then surface the panel so the user sees
            // that the press registered before the first token arrives. In
            // silent mode the panel stays hidden — Telegram is the only output.
            FrameWriter.shared.writeControl("hotkey", ["mode": mode])
            Task { @MainActor in
                guard let self, !self.silent else { return }
                self.panel.show()
            }
        }
        hotkeysOn = tap.start()
        if hotkeysOn { hotkeys = tap }
    }

    // MARK: - Core events

    private func handle(_ event: CoreEvent) {
        switch event.type {
        case "ready":
            running = true
            status = "Ready"
            telegramOn = (event.fields["telegram"] as? Bool) ?? false
            refreshUsage()
            // The armed project survives an app restart; the core does not —
            // re-brief it as soon as it can listen.
            if activeProject != nil { sendProjectContext() }
            startCapture()
        case "transcript":
            if let text = event.string("text") { lastHeard = text }
        case "audio_health":
            micLive = TrackHealth(rawValue: event.string("me") ?? "off") ?? .off
            systemLive = TrackHealth(rawValue: event.string("them") ?? "off") ?? .off
            // Logged so capture health can be confirmed from outside the app,
            // without clicking through to the menu.
            NSLog("audio health: mic=%@ system=%@", micLive.rawValue, systemLive.rawValue)
            if micLive == .stalled || systemLive == .stalled { recoverCapture() }
            status = statusLine()
        case "session_reset":
            // The history deliberately survives: "what did we answer last time"
            // is a question that most often reaches back across a call boundary.
            // The next answer just gets marked as the start of a new one.
            nextStartsCall = true
            lastHeard = ""
        case "ask_start":
            answering = true
            notice = nil
            beginAnswer(mode: event.string("mode") ?? "fast",
                        withShot: (event.fields["withShot"] as? Bool) ?? false,
                        question: event.string("typed"))
            if !silent { panel.show() }
        case "note_added":
            notice = "note taken — goes out with the next answer"
        case "project_context_set":
            // The engine's own ack — proof the files reached the system
            // prompt, not just the IPC socket (same idea as context_added).
            status = pendingProjectLine ?? "project context set"
            pendingProjectLine = nil
        case "typed_queued":
            notice = "finishing this answer — asking right after"
        case "scout_pulled":
            // The scout folded shelf files into the prompt because their topic
            // just came up. Worth a notice: the next answer may know things no
            // briefed file contains, and that must not look like a hallucination.
            let files = (event.fields["files"] as? [String]) ?? []
            notice = "pulled from the shelf: \(files.joined(separator: ", "))"
        case "first_token":
            if let ms = event.int("ms") {
                withLive {
                    let screen = $0.header.contains("· screen") ? " · screen" : ""
                    $0.header = "\($0.mode == "deep" ? "DEEP" : "FAST")\(screen) · first token \(ms) ms"
                }
            }
        case "answer_delta":
            withLive { $0.text += event.string("text") ?? "" }
        case "answer_done":
            answering = false
            if let total = event.int("totalMs") {
                withLive { $0.header += " · total \(total) ms" }
            }
            persistLive()
            if let spend = event.string("spend") { spendLine = spend }
        case "answer_error":
            answering = false
            withLive {
                $0.header = "answer failed"
                $0.text = event.string("message") ?? "unknown error"
            }
            persistLive()
        case "busy":
            withLive { $0.header += " · (still answering, press ignored)" }
        case "delivered":
            let ok = (event.fields["ok"] as? Bool) ?? false
            lastDelivery = ok
                ? "sent to \(event.string("target") ?? "telegram")"
                : "\(event.string("target") ?? "telegram") failed: \(event.string("error") ?? "?")"
            if !ok { NSLog("delivery failed: %@", lastDelivery) }
        case "usage":
            if let line = event.string("line") { spendLine = line }
            telegramOn = (event.fields["telegram"] as? Bool) ?? telegramOn
        case "telegram_test_result":
            let ok = (event.fields["ok"] as? Bool) ?? false
            status = ok
                ? "Telegram works — check the chat"
                : "Telegram failed: \(event.string("error") ?? "unknown")"
        case "fatal":
            running = false
            status = event.string("message") ?? "core failed"
        default:
            break
        }
    }

    // MARK: - Menu actions

    func ask(_ mode: String) {
        core.send("ask", ["mode": mode])
        if !silent { panel.show() }
    }

    /// Answer about what is on screen right now.
    ///
    /// The picture is taken BEFORE the question goes out, so this costs the
    /// user real time while they stand there. The panel therefore opens first
    /// and says what is happening — a silent pause is indistinguishable from a
    /// dead hotkey, and this one is pressed in front of other people.
    ///
    /// A failed capture does NOT fall through to a normal question: an answer
    /// about the transcript is not what was asked for, and it would arrive
    /// looking exactly like a successful one.
    func askScreen() {
        if !silent { panel.show() }
        notice = "taking the screen…"
        let target = ScreenShot.Target.parse(env["SCREEN_TARGET"] ?? "call")
        let pids = detector?.currentCallPIDs ?? []
        Task {
            do {
                // Logged because this is the whole price of the feature: it is
                // time the user spends standing in front of other people.
                let t0 = Date()
                let url = try await ScreenShot.capture(target, callPIDs: pids)
                let ms = Int(Date().timeIntervalSince(t0) * 1000)
                let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int ?? 0
                NSLog("screen captured in %d ms (%d KB) -> %@", ms, size / 1024, url.lastPathComponent)
                FrameWriter.shared.writeControl("hotkey", ["mode": "fast", "shot": url.path])
            } catch {
                notice = "could not capture the screen: \(error.localizedDescription)"
                NSLog("screen capture failed: %@", error.localizedDescription)
            }
        }
    }

    /// Silent: answers stop appearing on screen and go to Telegram only.
    func toggleSilent() {
        silent.toggle()
        if silent {
            panel.hide()
            status = telegramOn
                ? "Silent — answers go to Telegram only"
                : "Silent, but Telegram isn't set up: answers go nowhere"
        } else {
            status = statusLine()
        }
    }

    /// Refresh the spend readout (the menu asks for it when it opens).
    func refreshUsage() {
        core.send("usage")
    }

    func testTelegram() {
        status = "Testing Telegram…"
        core.send("telegram_test")
    }

    func resetSession() {
        core.send("reset")
        nextStartsCall = true
        lastHeard = ""
        status = "New call — the session is clear (answers are kept)"
        // A manual reset is a new call too — same freshness rule as call start.
        if activeProject != nil { sendProjectContext() }
    }

    // MARK: - Projects

    /// Save (or update) a project from the context window's folder selection.
    /// `shelf` = the readable files left unchecked — the mid-call scout's corpus.
    func saveProject(name: String, files: [String], shelf: [String] = []) {
        projectStore.upsert(Project(name: name, files: files, shelf: shelf))
        projects = projectStore.projects
        status = "Project “\(name)” saved (\(files.count) files"
            + (shelf.isEmpty ? "" : ", \(shelf.count) on the shelf")
            + ") — arm it in the menu"
    }

    /// Arm a project (nil = disarm). Armed = its files are read fresh from
    /// disk and sent as the project-context slot now, at every call start,
    /// and after an app restart.
    func activateProject(_ name: String?) {
        activeProject = name
        projectStore.setActive(name)
        sendProjectContext()
    }

    private func sendProjectContext() {
        guard running else { return } // the ready handler re-sends at boot
        guard let name = activeProject,
              let project = projects.first(where: { $0.name == name }) else {
            pendingProjectLine = "Project cleared"
            core.send("project_context", ["text": ""])
            return
        }
        let ctx = ProjectStore.buildContext(project)
        var line = "Project \(name): \(ctx.fileCount) files · \(ctx.text.count.formatted()) chars"
        if !ctx.problems.isEmpty {
            line += " · ⚠️ \(ctx.problems.joined(separator: ", "))"
        }
        if ctx.text.count > contextMaxChars {
            line += " · ⚠️ over the \(contextMaxChars.formatted())-char cap"
        }
        pendingProjectLine = line
        // The shelf rides in the same frame. writeControl only carries string
        // fields, so the paths travel as one JSON-encoded string — the core
        // decodes it (and treats anything malformed as an empty shelf).
        let shelfData = (try? JSONSerialization.data(withJSONObject: project.shelf))
            ?? Data("[]".utf8)
        core.send("project_context", [
            "text": ctx.text,
            "shelf": String(data: shelfData, encoding: .utf8) ?? "[]",
        ])
    }

    func addContext(_ text: String, source: String? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        core.send("context", ["text": trimmed])
        let size = "\(trimmed.count.formatted()) chars"
        status = source == nil ? "Context added (\(size))" : "Context added from \(source!) (\(size))"
    }

    /// Text typed into the panel. Silently = buffer it for the next answer;
    /// otherwise answer it right now (the core queues it if one is streaming).
    func sendTyped(_ text: String, silently: Bool) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        core.send("typed", ["text": trimmed, "mode": silently ? "note" : "fast"])
    }

    /// Input dollars per 1M tokens — mirrors core/src/pricing.ts. Unknown models
    /// fall back to the Opus rate so the readout errs high rather than low.
    private static func inputRate(for model: String) -> Double {
        switch model {
        case "claude-haiku-4-5": return 1
        case "claude-sonnet-5", "claude-sonnet-4-6": return 3
        case "claude-fable-5": return 10
        default: return 5 // opus-tier
        }
    }

    func quit() {
        NSApplication.shared.terminate(nil) // cleanup runs in applicationWillTerminate
    }

    /// Release the mic, the tap and the core (with its 3GB whisper-server).
    func shutdown() {
        mic?.stop()
        mic = nil
        detector?.stop()
        core.stop()
    }

    private func statusLine() -> String {
        if recovering { return "capture dropped — rebuilding…" }
        var parts: [String] = []
        parts.append("mic \(mark(micOn, micLive))")
        parts.append("system \(mark(systemOn, systemLive))")
        parts.append(hotkeysOn ? "hotkeys ✓" : "hotkeys ✗")
        return parts.joined(separator: " · ")
    }

    /// ✓ only while frames are actually arriving. "Started successfully once"
    /// is exactly the reassurance that let a dead microphone look healthy for
    /// ten hours, so it no longer earns a checkmark on its own.
    private func mark(_ started: Bool, _ live: TrackHealth) -> String {
        guard started else { return "✗" }
        switch live {
        case .live: return "✓"
        case .off: return "…"
        case .stalled: return "✗ STALLED"
        }
    }

    /// Everything needed for "is this thing actually going to hear the call?",
    /// in one glance before dialling in.
    var captureHealthy: Bool { micLive == .live && systemLive == .live }
}
