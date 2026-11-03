import SwiftUI
import AppKit

/// «How to use» — one scrollable crib, not documentation. Every section is an
/// answer to a question the author actually asked after building the thing
/// («how do I warm it up?», «where do I point it at a project?», «no audio») — if a
/// feature never produced a real question, it is not in here.
@MainActor
final class HelpWindow: NSObject {
    static let shared = HelpWindow()
    private var window: NSWindow?

    func show(state: AppState) {
        if window == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 480, height: 640),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false)
            w.title = "Livecall — how to use"
            w.isReleasedWhenClosed = false
            w.center()
            w.contentView = NSHostingView(rootView: HelpView(state: state))
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct HelpView: View {
    // Hotkey labels come from the live config, not from prose: a help window
    // that shows yesterday's binding after a .env rebind is worse than none.
    @ObservedObject var state: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                section("Before the call", [
                    "Start Livecall 2–3 minutes early: the model takes ~30–40 seconds to load, and the hotkeys stay silent until then — that is the load queue, not a failure.",
                    "Ready state: the menu-bar icon turns into a quote bubble and the menu status reads mic ✓ · system ✓ · hotkeys ✓. A checkmark means frames are arriving right now, not that capture started at some point.",
                    "Smoke test: press \(state.hotkeyFastLabel) once before the call — if the panel answers, the whole chain is alive. Then «New call» so the session starts clean.",
                ])
                section("Hotkeys", [
                    "\(state.hotkeyFastLabel) — a quick answer to the last question from the call.",
                    "\(state.hotkeyDeepLabel) — a thorough answer for big questions (may think for a few seconds).",
                    "\(state.hotkeyScreenLabel) — a question about what is on screen right now (takes and attaches a screenshot).",
                ])
                section("Panel", [
                    "The «→ …» line under the header is how the copilot understood the question. Wrong question — type a correction in the field at the bottom.",
                    "The orange «DO NOT READ ALOUD» zone is for your eyes only: «deeper, if they press» material and corrections to your own numbers.",
                    "The field at the bottom: ⏎ — ask or correct (during a stream it queues and goes right after), ⌥⏎ — note silently, it rides along with the next answer.",
                    "‹ › — answer history; «heard:» at the bottom — the last phrase picked up.",
                ])
                section("Projects and briefing", [
                    "Add call context… → attach the briefing folder → checked files = core (always in the prompt), unchecked files = shelf: the scout pulls them in on its own when the conversation reaches their topic, and the panel says «pulled from the shelf: …».",
                    "Save as project → arm it in the «Project: …» menu. Files are re-read from disk at every call start — edit the briefing up to a minute before the call.",
                    "How to write a briefing pack: BRIEFING.md in the repo root.",
                ])
                section("If no audio arrives", [
                    "A Bluetooth headset can silently drop the microphone capture. The reliable setup: System Settings → Sound → Input = the MacBook microphone, headphones for output only.",
                    "The panel warns on its own («no audio arriving», «rebuilding capture») — if the warning stays up, there really is no audio; it is not a false alarm.",
                ])
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 420, minHeight: 480)
    }

    private func section(_ title: String, _ rows: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            ForEach(rows, id: \.self) { row in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("·").foregroundStyle(.secondary)
                    Text(row)
                        .font(.system(size: 12))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Divider().padding(.top, 4)
        }
    }
}
