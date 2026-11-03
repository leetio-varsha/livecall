import Foundation
import AVFoundation

/// livecall-helper — captures mic ("me") + system audio ("them"), streams
/// 16kHz mono s16le PCM frames to stdout (protocol in FrameWriter.swift),
/// emits call_start/call_end control frames from CallDetector, and turns the
/// global hotkeys into hotkey control frames.
/// Flags: --no-mic  --no-system  --no-detect  --no-hotkey
///        --hotkey-fast <spec>  --hotkey-deep <spec>   (e.g. "opt+cmd+a")
///        --exclude-proc <a,b>  (process names that never count as a call)
@main
struct Main {
    static func main() async {
        let args = CommandLine.arguments
        let micEnabled = !args.contains("--no-mic")
        let sysEnabled = !args.contains("--no-system")
        let detectEnabled = !args.contains("--no-detect")
        let hotkeyEnabled = !args.contains("--no-hotkey")

        var sources = 0

        if micEnabled {
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            if granted {
                do {
                    let mic = MicCapture()
                    try await mic.start()
                    Retain.mic = mic
                    sources += 1
                    log("mic capture started (source=me)")
                } catch {
                    log("mic failed: \(error.localizedDescription)")
                }
            } else {
                log("mic permission denied (System Settings → Privacy & Security → Microphone)")
            }
        }

        if sysEnabled {
            do {
                let sys = SystemAudioCapture()
                try await sys.start()
                Retain.sys = sys
                sources += 1
                log("system audio capture started (source=them)")
            } catch {
                log("system audio failed — grant Screen Recording permission: \(error.localizedDescription)")
            }
        }

        if detectEnabled, sources > 0 {
            let det = CallDetector()
            if let extra = value(of: "--exclude-proc", in: args) {
                det.exclude(extra.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
            }
            det.onCallStart = { FrameWriter.shared.writeControl("call_start") }
            det.onCallEnd = { FrameWriter.shared.writeControl("call_end") }
            det.start()
            Retain.det = det
            log("call auto-detect on")
        }

        let hotkeysArmed = hotkeyEnabled && startHotkeys(args)

        // Hotkeys alone are still useful (they drive the core's REPL actions),
        // so only quit when the process has nothing at all to do.
        guard sources > 0 || hotkeysArmed else {
            log("no audio sources and no hotkeys available — exiting")
            exit(1)
        }
        if sources == 0 {
            log("running hotkeys-only — no audio is being captured")
        }

        ParentWatchdog.start()

        log("ready")
        while true {
            try? await Task.sleep(nanoseconds: 3_600_000_000_000)
        }
    }

    /// Arms the global hotkeys. A refused tap is not fatal — the core keeps its
    /// terminal REPL, so capture must go on either way.
    @discardableResult
    private static func startHotkeys(_ args: [String]) -> Bool {
        let parsed = HotkeySpecs.parse([
            (mode: "fast", spec: value(of: "--hotkey-fast", in: args) ?? "ropt"),
            (mode: "deep", spec: value(of: "--hotkey-deep", in: args) ?? "shift+ropt"),
        ])
        for bad in parsed.bad {
            log("bad hotkey spec \"\(bad)\" — that hotkey is off")
        }
        guard !parsed.isEmpty else { return false }

        let tap = HotkeyTap(combos: parsed.combos, taps: parsed.taps) { mode in
            FrameWriter.shared.writeControl("hotkey", ["mode": mode])
        }
        guard tap.start() else {
            log("""
                hotkeys unavailable: macOS refused the event tap. Grant the app you \
                launch Livecall from (your terminal, for now) both Accessibility and \
                Input Monitoring in System Settings → Privacy & Security, then restart. \
                Terminal Enter / /deep still work.
                """)
            return false
        }
        Retain.hotkey = tap
        log("hotkeys armed — " + parsed.labels.joined(separator: ", "))
        return true
    }

    private static func value(of flag: String, in args: [String]) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }
}

/// Keeps captures alive for the lifetime of the process.
enum Retain {
    static var mic: MicCapture?
    static var sys: SystemAudioCapture?
    static var det: CallDetector?
    static var hotkey: HotkeyTap?
}
