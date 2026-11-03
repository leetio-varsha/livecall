import SwiftUI
import AppKit
import AVFoundation

/// Entry point. Everything except `--core-selftest` starts the menu-bar app.
@main
enum Launch {
    static func main() {
        if CommandLine.arguments.contains("--core-selftest") {
            CoreSelfTest.run()
        }
        if CommandLine.arguments.contains("--tcc-report") {
            TccReport.run()
        }
        if let i = CommandLine.arguments.firstIndex(of: "--context-selftest"),
           i + 1 < CommandLine.arguments.count {
            contextSelfTest(path: CommandLine.arguments[i + 1])
        }
        if let i = CommandLine.arguments.firstIndex(of: "--project-selftest"),
           i + 1 < CommandLine.arguments.count {
            projectSelfTest(folder: CommandLine.arguments[i + 1])
        }
        if CommandLine.arguments.contains("--panel-selftest") {
            panelSelfTest()
        }
        if CommandLine.arguments.contains("--help-selftest") {
            helpSelfTest()
        }
        LivecallApp.main()
    }
}

/// SwiftUI gives a MenuBarExtra-only app no launch hook, so capture and the
/// core are started from the AppKit delegate — and stopped there too, which is
/// what keeps a 3GB whisper-server from outliving the app.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_: Notification) {
        MainActor.assumeIsolated { AppState.shared.boot() }
    }

    func applicationWillTerminate(_: Notification) {
        MainActor.assumeIsolated { AppState.shared.shutdown() }
    }
}

struct LivecallApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var state = AppState.shared

    var body: some Scene {
        MenuBarExtra {
            LivecallMenu().environmentObject(state)
        } label: {
            Image(systemName: state.menuIcon)
        }
        .menuBarExtraStyle(.menu)
    }
}

struct LivecallMenu: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Text("Livecall — \(state.status)")
        // The pre-call check: this says whether audio is ARRIVING, not whether
        // capture once started. Only the first fact predicts a useful answer.
        if state.running && !state.captureHealthy {
            Text(state.recovering
                 ? "⏳ rebuilding capture…"
                 : "⚠️ no audio arriving — restart Livecall before the call")
        }
        if !state.spendLine.isEmpty {
            Text(state.spendLine)
        }
        Divider()
        Button("Ask now — FAST (\(state.hotkeyFastLabel))") { state.ask("fast") }
            .disabled(!state.running)
        Button("Ask now — DEEP (\(state.hotkeyDeepLabel))") { state.ask("deep") }
            .disabled(!state.running)
        Button("Ask about the screen (\(state.hotkeyScreenLabel))") { state.askScreen() }
            .disabled(!state.running)
        Button("Show / hide the answer panel") { state.panel.toggle() }
            .disabled(state.silent)
        Divider()
        Toggle("Silent — Telegram only, no panel", isOn: Binding(
            get: { state.silent },
            set: { _ in state.toggleSilent() }))
        if !state.lastDelivery.isEmpty {
            Text(state.lastDelivery)
        }
        Divider()
        Button("New call (clear the session)") { state.resetSession() }
        Button("Add call context…") { ContextWindow.shared.show(state: state) }
        // Armed project = its files are re-read from disk and re-briefed on
        // every call start. Toggles, not buttons: the checkmark IS the state,
        // and unchecking the active one disarms cleanly.
        if !state.projects.isEmpty {
            Menu("Project: \(state.activeProject ?? "none")") {
                ForEach(state.projects) { project in
                    Toggle(project.name, isOn: Binding(
                        get: { state.activeProject == project.name },
                        set: { on in state.activateProject(on ? project.name : nil) }))
                }
            }
            .disabled(!state.running)
        }
        // The history is a transcript of real answers on real calls, so wiping
        // it has to be one click away rather than a file to go find.
        Button("Clear the answer history (\(state.history.count))") { state.clearHistory() }
            .disabled(state.history.isEmpty)
        Divider()
        Button("How to use…") { HelpWindow.shared.show(state: state) }
        Button("Permissions & setup…") { OnboardingWindow.shared.show(state: state) }
        Button("Quit Livecall") { state.quit() }
    }
}

/// `Livecall --context-selftest <path>` — no GUI. For a file: extract text and
/// print what attaching it would cost. For a folder: scan it exactly the way
/// the Attach button would and print every candidate with its estimate. This
/// is the part worth testing headlessly: PDFKit extraction (incl. Cyrillic),
/// the scan detection, the folder walk, the size cap, and the cost estimate.
@MainActor
private func contextSelfTest(path: String) -> Never {
    let url = URL(fileURLWithPath: path)
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
        print("RESULT: ❌ no such path: \(url.path)")
        exit(1)
    }
    if isDir.boolValue { folderSelfTest(url) }
    let cap = Int(EnvFile.load("\(BuildConfig.repoRoot)/core/.env")["CONTEXT_MAX_CHARS"] ?? "") ?? 60_000
    do {
        var text = try ContextView.extractText(from: url)
        let raw = text.count
        print("file:      \(url.lastPathComponent)")
        print("extracted: \(raw) chars")
        if text.trimmingCharacters(in: .whitespacesAndNewlines).count < 20 {
            print(url.pathExtension.lowercased() == "pdf"
                  ? "RESULT: ❌ no text layer — a scan; OCR is not supported"
                  : "RESULT: ❌ file is empty")
            exit(1)
        }
        if raw > cap {
            text = String(text.prefix(cap))
            print("trimmed:   \(text.count) chars (cap \(cap))")
        }
        let e = ContextEstimate.of(text, inputRatePer1M: 5.0, cacheWritePremium: 2.0)
        print("tokens:    ≈\(e.tokens)")
        print(String(format: "cost:      first press ≈$%.4f, each later press ≈$%.4f", e.firstPressUSD, e.laterPressUSD))
        print("--- first 200 chars ---")
        print(String(text.prefix(200)).replacingOccurrences(of: "\n", with: " ⏎ "))
        print("RESULT: ✅ readable")
        exit(0)
    } catch {
        print("RESULT: ❌ \(error.localizedDescription)")
        exit(1)
    }
}

/// The folder half of `--context-selftest`: what the selection list will show,
/// what starts checked (the BRIEFING.md convention), and what it would cost.
/// `--shot <out.png>` additionally renders the actual window layout offscreen —
/// no window server involved, so no Screen Recording permission and nothing
/// flashes on screen while the user might be on a call.
@MainActor
private func folderSelfTest(_ root: URL) -> Never {
    let cap = Int(EnvFile.load("\(BuildConfig.repoRoot)/core/.env")["CONTEXT_MAX_CHARS"] ?? "") ?? 60_000
    let scan = FolderScan.scan(root)
    let readable = scan.files.filter { $0.problem == nil }
    print("folder:    \(root.lastPathComponent)")
    print("readable:  \(readable.count) of \(scan.files.count) candidates\(scan.hitCap ? " (scan hit its cap)" : "")")
    for f in scan.files {
        if let why = f.problem {
            print("  [!] \(f.name) — \(why)")
        } else {
            let when = f.modified.map { FolderScan.mtime.string(from: $0) } ?? "?"
            print("  [\(f.selected ? "x" : " ")] \(f.name)  \(f.chars) chars  ≈\(f.tokens) tok  modified \(when)")
        }
    }
    let preselected = readable.filter(\.selected)
    if !preselected.isEmpty {
        let chars = preselected.reduce(0) { $0 + $1.chars }
        let e = ContextEstimate(
            chars: chars,
            tokens: preselected.reduce(0) { $0 + $1.tokens },
            inputRatePer1M: 5.0, cacheWritePremium: 2.0)
        print(String(
            format: "preselected: %d file(s) · %d chars of the %d cap · ≈%d tok — first press ≈$%.4f, later ≈$%.4f",
            preselected.count, chars, cap, e.tokens, e.firstPressUSD, e.laterPressUSD))
    }
    let verdict = readable.isEmpty ? "RESULT: ❌ nothing readable" : "RESULT: ✅ folder attachable"
    let code: Int32 = readable.isEmpty ? 1 : 0
    if let i = CommandLine.arguments.firstIndex(of: "--shot"), i + 1 < CommandLine.arguments.count {
        let out = URL(fileURLWithPath: CommandLine.arguments[i + 1])
        NSApplication.shared.setActivationPolicy(.accessory)
        // The view draws its text only inside a real, briefly shown window:
        // both ImageRenderer and window-less cacheDisplay come back with the
        // controls but placeholder boxes where the editor and the list belong.
        // One second of a small window is the price of an honest screenshot.
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 560),
            styleMask: [.titled], backing: .buffered, defer: false)
        win.title = "Call context — selftest"
        win.contentView = NSHostingView(
            rootView: ContextView(state: AppState.shared, initialScan: scan) {})
        win.center()
        win.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            // Window-server capture of our OWN window (no Screen Recording
            // prompt): SwiftUI text lives in CoreAnimation layers, which
            // cacheDisplay silently skips — this is the one path that returns
            // the pixels the user would actually see.
            if let cg = CGWindowListCreateImage(
                .null, .optionIncludingWindow, CGWindowID(win.windowNumber),
                [.boundsIgnoreFraming, .bestResolution]) {
                let png = NSBitmapImageRep(cgImage: cg)
                    .representation(using: .png, properties: [:])
                do {
                    try png?.write(to: out)
                    print("shot:      \(out.path)")
                } catch {
                    print("shot:      ❌ \(error.localizedDescription)")
                }
            } else {
                print("shot:      ❌ window capture returned nothing")
            }
            print(verdict)
            exit(code)
        }
        NSApplication.shared.run()
    }
    print(verdict)
    exit(code)
}

/// `Livecall --project-selftest <folder>` — no GUI. Exercises the whole project
/// path against a THROWAWAY store: scan the folder, save its readable files
/// as a project, reload the store from disk, build the context fresh, and
/// prove that a vanished file surfaces as a problem instead of a silent gap.
private func projectSelfTest(folder: String) -> Never {
    let root = URL(fileURLWithPath: folder)
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("livecall-project-selftest-\(ProcessInfo.processInfo.processIdentifier).json")
    defer { try? FileManager.default.removeItem(at: tmp) }

    let files = FolderScan.scan(root).files.filter { $0.problem == nil }.map(\.url.path)
    guard !files.isEmpty else {
        print("RESULT: ❌ no readable files in \(root.path)")
        exit(1)
    }

    let store = ProjectStore(url: tmp)
    // The shelf never gets read at save time, so a path that does not exist is
    // fine here — this asserts persistence, not readability.
    let shelf = [root.appendingPathComponent("unchecked-extra.md").path]
    store.upsert(Project(name: "selftest", files: files, shelf: shelf))
    store.setActive("selftest")

    let reloaded = ProjectStore(url: tmp)
    guard reloaded.activeName == "selftest",
          let project = reloaded.projects.first(where: { $0.name == "selftest" }),
          project.files == files, project.shelf == shelf else {
        print("RESULT: ❌ store round-trip lost data")
        exit(1)
    }
    print("store:     round-trip ok (\(project.files.count) files + \(project.shelf.count) shelf, active preserved)")

    // A projects.json written before the shelf existed has no such key. It
    // must decode as an empty shelf — a decode failure here would silently
    // drop EVERY saved project on the first launch after the update.
    let legacyURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("livecall-project-selftest-legacy-\(ProcessInfo.processInfo.processIdentifier).json")
    defer { try? FileManager.default.removeItem(at: legacyURL) }
    try? Data(#"{"active":"old","projects":[{"name":"old","files":["/a.md"]}]}"#.utf8)
        .write(to: legacyURL)
    let legacy = ProjectStore(url: legacyURL)
    guard let old = legacy.projects.first(where: { $0.name == "old" }), old.shelf.isEmpty else {
        print("RESULT: ❌ pre-shelf projects.json no longer decodes")
        exit(1)
    }
    print("legacy:    pre-shelf store decodes, shelf reads empty")

    let ctx = ProjectStore.buildContext(project)
    print("context:   \(ctx.fileCount) files · \(ctx.text.count) chars · problems: \(ctx.problems.isEmpty ? "none" : ctx.problems.joined(separator: ", "))")
    guard ctx.fileCount == files.count, ctx.problems.isEmpty,
          ctx.text.contains("=== FILE: ") else {
        print("RESULT: ❌ context build lost files")
        exit(1)
    }

    // A file that disappears between saving and the call MUST be loud.
    var broken = project
    broken.files.append(root.appendingPathComponent("no-such-file.md").path)
    let withMissing = ProjectStore.buildContext(broken)
    guard withMissing.problems.contains(where: { $0.contains("no-such-file.md") }) else {
        print("RESULT: ❌ missing file was skipped silently")
        exit(1)
    }
    print("missing:   surfaced as a problem, not skipped")
    print("RESULT: ✅ project store + context build ok")
    exit(0)
}

/// `Livecall --panel-selftest` — build and show the answer panel outside the
/// event loop, so any AppKit exception surfaces with its reason instead of
/// being swallowed and logged as a redacted FAULT.
@MainActor
private func helpSelfTest() -> Never {
    NSApplication.shared.setActivationPolicy(.accessory)
    let state = AppState.shared
    HelpWindow.shared.show(state: state)
    // Same capture path as the other window selftests: SwiftUI text lives in
    // CA layers, so only the window server returns honest pixels.
    if let i = CommandLine.arguments.firstIndex(of: "--shot"),
       i + 1 < CommandLine.arguments.count {
        let out = URL(fileURLWithPath: CommandLine.arguments[i + 1])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            if let win = NSApp.windows.first(where: { $0.title.hasPrefix("Livecall — how") }),
               let cg = CGWindowListCreateImage(
                   .null, .optionIncludingWindow, CGWindowID(win.windowNumber),
                   [.boundsIgnoreFraming, .bestResolution]),
               let png = NSBitmapImageRep(cgImage: cg)
                   .representation(using: .png, properties: [:]) {
                try? png.write(to: out)
                print("shot:      \(out.path)")
            } else {
                print("shot:      ❌ window capture returned nothing")
            }
            exit(0)
        }
        NSApplication.shared.run()
    }
    exit(0)
}

@MainActor
private func panelSelfTest() -> Never {
    let err = FileHandle.standardError
    err.write(Data("creating NSApplication…\n".utf8))
    NSApplication.shared.setActivationPolicy(.accessory)
    let state = AppState.shared
    let panel = AnswerPanel(state: state)

    // `--hold` fills the panel with a two-audience answer and keeps it on
    // screen, so the spoken/not-spoken split can be eyeballed (and screenshot)
    // without waiting for a real call to produce one.
    // Three answers, not one: the paging controls and the "you are looking at
    // an old answer" banner only exist once there is a history to page through.
    // `--older` starts one step back, which is the state worth checking.
    let hold = CommandLine.arguments.contains("--hold")
    if hold {
        state.seedPreview([
            (question: "How does the sync handle a device that was offline for a week?",
             header: "preview · FAST · total 3210 ms",
             text: """
                It replays the device's queue in order when it reconnects. Every record carries \
                the device clock and our receive time, so a week-old batch lands in the right \
                place instead of overwriting newer data.
                """,
             startsCall: true),
            (question: "And what happens if two devices edit the same record?",
             header: "preview · FAST · total 2870 ms",
             text: """
                Last write wins per field, not per record — two people editing different fields \
                of the same card both keep their change. A real conflict on one field is rare, \
                and we show both values rather than picking one silently.
                """,
             startsCall: false),
            (question: "How would you roll out a schema change without taking the service down?",
             header: "preview · FAST · first token 640 ms",
             text: """
                → rolling out a schema change with no downtime

                I would not rename a column in place — it breaks the running code the moment it \
                ships. I do it in three steps: add the new column and write to both, switch reads \
                to the new one and backfill the old rows, and only drop the old column a release \
                or two later. Happy to go into the rollback if that helps.

                Deeper (if they press): the migration has to work with both the old and the new \
                code version — during the rollout they run side by side for a while. For big \
                tables the backfill goes in batches, not one UPDATE.
                """,
             startsCall: false),
        ])
        state.lastHeard = "How would you roll out a schema change without taking the service down?"
        // Repeatable: `--older --older` lands on the first answer of the call,
        // which is the one carrying the call-start mark.
        for _ in 0..<CommandLine.arguments.filter({ $0 == "--older" }).count { state.showOlder() }
    }

    err.write(Data("showing panel…\n".utf8))
    panel.show()
    err.write(Data("visible: \(panel.isVisible)\n".utf8))
    if hold {
        // The panel must appear WITHOUT taking key status or activating the
        // app: it floats over a call the user is in the middle of. When it did
        // take key, the next key event hit a window with no responder for it
        // and macOS beeped on every press. Reported here because that is a
        // regression nothing else would notice — the panel looks identical
        // either way. Read after a runloop spin: key status settles async.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            let key = NSApp.windows.first { $0.isKeyWindow }?.title ?? "none"
            err.write(Data("focus check — key window: \(key), app active: \(NSApp.isActive)\n".utf8))
            // `--shot <out.png>`: capture the panel and exit instead of holding.
            // Window-server capture of our own window, same as the context
            // selftest — SwiftUI text never survives cacheDisplay.
            if let i = CommandLine.arguments.firstIndex(of: "--shot"),
               i + 1 < CommandLine.arguments.count,
               let win = NSApp.windows.first(where: { $0.title == "Livecall" }) {
                let out = URL(fileURLWithPath: CommandLine.arguments[i + 1])
                if let cg = CGWindowListCreateImage(
                    .null, .optionIncludingWindow, CGWindowID(win.windowNumber),
                    [.boundsIgnoreFraming, .bestResolution]),
                   let png = NSBitmapImageRep(cgImage: cg)
                       .representation(using: .png, properties: [:]) {
                    try? png.write(to: out)
                    err.write(Data("shot: \(out.path)\n".utf8))
                }
                exit(0)
            }
        }
        NSApplication.shared.run() // until killed
    }
    exit(panel.isVisible ? 0 : 1)
}

enum AVPermissions {
    static func requestMic() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }
}
