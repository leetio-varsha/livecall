import SwiftUI
import AppKit

/// Floating answer window. It must never steal focus from the call app, so it
/// is a non-activating panel: it can be clicked (to scroll or copy) without
/// pulling the user out of Zoom/Meet mid-sentence.
final class AnswerPanel: NSObject {
    private var panel: NSPanel?
    private let state: AppState

    init(state: AppState) {
        self.state = state
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    func show() {
        if panel == nil { build() }
        // orderFrontRegardless, NOT makeKeyAndOrderFront: the call app keeps focus.
        panel?.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    func toggle() {
        isVisible ? hide() : show()
    }

    private func build() {
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 320),
            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        p.title = "Livecall"
        p.titlebarAppearsTransparent = true
        p.isFloatingPanel = true
        p.level = .floating
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        // .nonactivatingPanel keeps the APP from activating; it does nothing
        // about this WINDOW taking key status, and an NSPanel takes it by
        // default. Measured: after orderFrontRegardless the panel was the key
        // window and the process was active — so the answer appearing pulled
        // focus out of Zoom, and the next key event landed on a window with no
        // responder for it, which is the system beep heard on every DEEP press.
        // Nothing here reads the keyboard, so it never needs to be key.
        p.becomesKeyOnlyIfNeeded = true
        // Follow the user across Spaces and float over a full-screen Zoom.
        // (.canJoinAllSpaces and .moveToActiveSpace are mutually exclusive —
        // setting both throws NSInternalInconsistencyException.)
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = NSHostingView(rootView: AnswerView().environmentObject(state))

        // Top-right of the screen with the menu bar, clear of the notch area.
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            p.setFrameOrigin(NSPoint(x: f.maxX - p.frame.width - 24, y: f.maxY - p.frame.height - 24))
        }
        panel = p
    }
}

/// An answer has two audiences. The top is written FOR THE ROOM — the user
/// reads it out loud. Anything after a «Deeper …:» line or a `---` footnote
/// rule is written FOR THE USER: follow-up material and term glosses that make
/// no sense spoken ("Deeper, if they press, colon"). The panel used to
/// render both as one flat block of identical text, which is a trap you only
/// spring once, live, in front of other people.
///
/// Mirrored in TypeScript as `splitAnswer` in core/src/answerParts.ts, which
/// Telegram delivery uses. The panel splits mid-stream so it cannot call that
/// one — change both together, and core's selftest covers the shared cases.
struct SplitAnswer {
    /// The model's restatement of the question it picked (the `→` line that
    /// prompts/answer.md opens every answer with). Shown small, never spoken.
    let reading: String?
    /// Safe to say out loud.
    let spoken: String
    /// Never say this out loud.
    let note: String?

    static func of(_ text: String) -> SplitAnswer {
        var reading: String?
        var body = text
        let lead = text.drop(while: \.isWhitespace)
        if lead.hasPrefix("→") {
            if let nl = lead.firstIndex(of: "\n") {
                reading = String(lead[lead.index(after: lead.startIndex)..<nl])
                    .trimmingCharacters(in: .whitespaces)
                body = String(lead[lead.index(after: nl)...])
            } else {
                // Mid-stream: the reading line is still arriving — show it
                // growing in its own slot, with nothing spoken yet.
                reading = String(lead.dropFirst()).trimmingCharacters(in: .whitespaces)
                body = ""
            }
            if reading?.isEmpty == true { reading = nil }
        }

        let lines = body.components(separatedBy: "\n")
        for (i, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // `---` opens the footnote block that prompts/answer.md defines.
            let isFootnoteRule = trimmed == "---"
            // «Deeper (if they press):» — the briefing convention, see BRIEFING.md.
            // Matched loosely: the wording is the model's, only the lead is fixed.
            let isDeeper = trimmed.lowercased().hasPrefix("deeper") && trimmed.contains(":")
            guard isFootnoteRule || isDeeper else { continue }

            let spoken = lines[..<i].joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // Drop the marker itself — the divider below says the same thing,
            // louder — but keep anything trailing it on the same line.
            var rest: [String] = []
            if isDeeper, let colon = trimmed.firstIndex(of: ":") {
                let tail = trimmed[trimmed.index(after: colon)...]
                    .trimmingCharacters(in: .whitespaces)
                if !tail.isEmpty { rest.append(tail) }
            }
            rest.append(contentsOf: lines[(i + 1)...])
            let note = rest.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // Mid-stream the marker can arrive before its body: keep the
            // section visible from that moment so it never reads as spoken.
            return SplitAnswer(reading: reading, spoken: spoken, note: note.isEmpty ? "…" : note)
        }
        return SplitAnswer(
            reading: reading,
            spoken: body.trimmingCharacters(in: .whitespacesAndNewlines),
            note: nil)
    }
}

struct AnswerView: View {
    @EnvironmentObject var state: AppState
    @State private var draft = ""

    /// One split per render, shared by the pinned reading line and the scroll.
    private var parts: SplitAnswer { SplitAnswer.of(state.answer) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle()
                    .fill(state.answering ? Color.orange : Color.secondary.opacity(0.5))
                    .frame(width: 7, height: 7)
                Text(state.answerHeader)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                historyNav
                if !state.answer.isEmpty {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(state.answer, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .help("Copy the answer")
                }
            }

            if state.viewingHistory { historyBanner }

            // "taking the screen…" — a screen question spends a beat taking the
            // picture before anything else can happen, and a silent pause in
            // front of other people reads as a dead hotkey.
            if let notice = state.notice {
                HStack(spacing: 6) {
                    Image(systemName: "camera.viewfinder").font(.system(size: 10))
                    Text(notice)
                        .font(.system(size: 10, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }
                .foregroundStyle(.secondary)
            }

            // A dead capture and a quiet room produce the same empty answer.
            // Say which one it is, in the place he is already looking.
            if state.running && !state.captureHealthy {
                HStack(spacing: 6) {
                    Image(systemName: state.recovering
                          ? "arrow.triangle.2.circlepath"
                          : "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                    Text(state.recovering
                         ? "audio dropped — rebuilding capture…"
                         : "no audio arriving: \(state.micLive == .live ? "" : "microphone ")"
                           + "\(state.systemLive == .live ? "" : "system audio")")
                        .font(.system(size: 11, weight: .medium))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }
                .foregroundStyle(.orange)
            }

            // The model's own reading of the question it picked. Pinned above
            // the divider, not inside the scroll: its whole job is to be seen
            // in the first second, before any words get said — and it is the
            // earliest thing the stream delivers, so it appears while the
            // answer body is still on its way.
            if let reading = parts.reading {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.system(size: 9))
                    Text(reading)
                        .font(.system(size: 11))
                        .italic()
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }
                .foregroundStyle(.secondary)
            }

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if state.current?.startsCall == true { callStartMark }
                        if state.answer.isEmpty {
                            Text(placeholder)
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            // Bigger than the old 13pt: this is read at a glance,
                            // mid-sentence, without leaning into the screen.
                            Text(parts.spoken)
                                .font(.system(size: 15))
                                .lineSpacing(2)
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)

                            if let note = parts.note {
                                noteDivider
                                Text(note)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .id("answer")
                }
                .onChange(of: state.answer) { _, _ in
                    // Follow the stream as it grows.
                    proxy.scrollTo("answer", anchor: .bottom)
                }
                .onChange(of: state.viewing) { _, _ in
                    // A different answer starts at ITS top, not wherever the
                    // previous one happened to be scrolled to.
                    proxy.scrollTo("answer", anchor: .top)
                }
            }

            if !heardLine.isEmpty {
                Divider()
                Text("heard: \(heardLine)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            // Typed input to the copilot. The panel is a non-activating
            // utility panel with becomesKeyOnlyIfNeeded, so this field takes
            // key status only when CLICKED — an arriving answer never moves
            // focus here, and the call app stays active either way.
            HStack(spacing: 6) {
                Image(systemName: "keyboard")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                TextField("Ask ⏎ · Note silently ⌥⏎", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .onSubmit { sendDraft(silently: false) }
                    // ⌥⏎ must be caught BEFORE the field submits: onSubmit
                    // carries no modifiers, onKeyPress does.
                    .onKeyPress(.return, phases: .down) { press in
                        guard press.modifiers.contains(.option) else { return .ignored }
                        sendDraft(silently: true)
                        return .handled
                    }
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
        }
        .padding(12)
        .frame(minWidth: 320, minHeight: 200)
    }

    /// Enter = answer the typed text now (or right after the current stream —
    /// the core queues it). ⌥Enter = remember silently for the next answer.
    private func sendDraft(silently: Bool) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        state.sendTyped(text, silently: silently)
        draft = ""
    }

    /// Paging back shows that answer's own question, not whatever the room has
    /// said since.
    private var heardLine: String {
        state.viewingHistory ? (state.current?.question ?? "") : state.lastHeard
    }

    /// Only worth the width once there is somewhere to go.
    @ViewBuilder private var historyNav: some View {
        if state.history.count > 1 {
            HStack(spacing: 3) {
                Button { state.showOlder() } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.borderless)
                    .disabled(!state.canShowOlder)
                    .help("Previous answer")
                Text("\(state.viewing + 1)/\(state.history.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button { state.showNewer() } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(.borderless)
                    .disabled(!state.canShowNewer)
                    .help("Next answer")
            }
        }
    }

    /// The one failure this feature could cause is reading a stale answer out
    /// loud believing it is the one just asked for. So paging back doesn't look
    /// subtly different — it looks like a different mode, with the way back one
    /// click away.
    private var historyBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "clock.arrow.circlepath").font(.system(size: 10))
            Text("history · \(state.stepsBack) back\(timeSuffix)")
                .font(.system(size: 10, weight: .semibold))
            Spacer()
            Button("latest") { state.showNewest() }
                .buttonStyle(.borderless)
                .font(.system(size: 10, weight: .semibold))
        }
        .foregroundStyle(.blue)
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(Color.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
    }

    private var timeSuffix: String {
        guard let at = state.current?.at else { return "" }
        return " · " + at.formatted(date: .omitted, time: .shortened)
    }

    /// Paging back must not silently cross into a different conversation.
    private var callStartMark: some View {
        HStack(spacing: 6) {
            Text("call start")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
            Rectangle().fill(Color.secondary.opacity(0.25)).frame(height: 1)
        }
    }

    /// Loud enough that the eye stops here even while the mouth is still
    /// finishing the previous sentence.
    private var noteDivider: some View {
        HStack(spacing: 6) {
            Image(systemName: "eye.slash.fill").font(.system(size: 9))
            Text("DO NOT READ ALOUD · if they press")
                .font(.system(size: 9, weight: .semibold))
                .kerning(0.6)
            Rectangle().fill(Color.orange.opacity(0.35)).frame(height: 1)
        }
        .foregroundStyle(.orange)
        .padding(.top, 2)
    }

    private var placeholder: String {
        state.answering ? "…" : "Press \(state.hotkeyFastLabel) during a call and the answer lands here."
    }
}
