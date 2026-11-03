import SwiftUI
import AppKit
import AVFoundation
import CoreGraphics
import ApplicationServices

/// "Why isn't it working" window: the four TCC grants Livecall needs, each
/// with a button that opens the exact System Settings pane, plus the two
/// non-macOS prerequisites (node on PATH, a key in core/.env). Statuses
/// refresh while it's open, so granting one updates the row without a restart.
@MainActor
final class OnboardingWindow: NSObject {
    static let shared = OnboardingWindow()
    private var window: NSWindow?

    func show(state: AppState) {
        if window == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 460, height: 530),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false)
            w.title = "Livecall setup"
            w.isReleasedWhenClosed = false
            w.center()
            w.contentView = NSHostingView(rootView: OnboardingView(repoRoot: state.repoRoot))
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct PermissionRow: Identifiable {
    let id = UUID()
    let name: String
    let why: String
    let granted: Bool
    let settingsURL: String?
}

struct OnboardingView: View {
    let repoRoot: String
    @State private var rows: [PermissionRow] = []
    @State private var nodeFound = false
    @State private var hasKey = false
    @State private var telegramConfigured = false
    private let tick = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Permissions")
                .font(.headline)
            Text("macOS attaches these to Livecall.app itself. After granting one, quit and relaunch Livecall — macOS only re-reads some of them at launch.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(rows) { row in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: row.granted ? "checkmark.circle.fill" : "exclamationmark.circle")
                        .foregroundStyle(row.granted ? .green : .orange)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.name).font(.system(size: 12, weight: .medium))
                        Text(row.why).font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !row.granted, let url = row.settingsURL {
                        Button("Open") { NSWorkspace.shared.open(URL(string: url)!) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
            }

            Divider()
            Text("Local setup").font(.headline)
            HStack(spacing: 8) {
                Image(systemName: nodeFound ? "checkmark.circle.fill" : "exclamationmark.circle")
                    .foregroundStyle(nodeFound ? .green : .orange)
                Text(nodeFound ? "node found on the login PATH" : "node not found — install Node ≥ 22")
                    .font(.system(size: 12))
            }
            HStack(spacing: 8) {
                Image(systemName: hasKey ? "checkmark.circle.fill" : "exclamationmark.circle")
                    .foregroundStyle(hasKey ? .green : .orange)
                Text(hasKey
                     ? "core/.env has an API key"
                     : "no ANTHROPIC_API_KEY / OPENAI_API_KEY in core/.env (falls back to the claude CLI)")
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            Text("Telegram").font(.headline)
            HStack(spacing: 8) {
                Image(systemName: telegramConfigured ? "checkmark.circle.fill" : "exclamationmark.circle")
                    .foregroundStyle(telegramConfigured ? .green : .orange)
                Text(telegramConfigured
                     ? "bot token + chat id are set in core/.env"
                     : "add TELEGRAM_BOT_TOKEN (from @BotFather) to core/.env")
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                if telegramConfigured {
                    Button("Send test") { AppState.shared.testTelegram() }
                        .buttonStyle(.bordered).controlSize(.small)
                }
            }

            Spacer()
        }
        .padding(18)
        .frame(width: 460, height: 530, alignment: .topLeading)
        .onAppear(perform: refresh)
        .onReceive(tick) { _ in refresh() }
    }

    private func refresh() {
        let prefix = "x-apple.systempreferences:com.apple.preference.security?Privacy_"
        rows = [
            PermissionRow(
                name: "Microphone",
                why: "your side of the call — the [Me] track",
                granted: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
                settingsURL: prefix + "Microphone"),
            PermissionRow(
                name: "Screen & System Audio Recording",
                why: "the other side — system audio, the [Them] track",
                granted: CGPreflightScreenCaptureAccess(),
                settingsURL: prefix + "ScreenCapture"),
            PermissionRow(
                name: "Accessibility",
                why: "the global hotkey, and swallowing it so the call app never sees it",
                granted: AXIsProcessTrusted(),
                settingsURL: prefix + "Accessibility"),
            PermissionRow(
                name: "Input Monitoring",
                why: "seeing the hotkey at all while another app is in front",
                granted: CGPreflightListenEventAccess(),
                settingsURL: prefix + "ListenEvent"),
        ]

        let env = EnvFile.load("\(repoRoot)/core/.env")
        hasKey = !(env["ANTHROPIC_API_KEY"] ?? "").isEmpty || !(env["OPENAI_API_KEY"] ?? "").isEmpty
        telegramConfigured = !(env["TELEGRAM_BOT_TOKEN"] ?? "").isEmpty
            && !(env["TELEGRAM_CHAT_ID"] ?? "").isEmpty
        nodeFound = FileManager.default.isExecutableFile(atPath: loginNodePath() ?? "")
    }

    private func loginNodePath() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "command -v node"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
