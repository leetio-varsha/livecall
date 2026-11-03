import Foundation
import AVFoundation
import CoreGraphics
import ApplicationServices
import AppKit

/// `Livecall --tcc-report` — print which macOS permissions this exact bundle has,
/// and exit non-zero if any is missing. Same checks as the setup window, but
/// runnable from a terminal: the answer to "it just doesn't react to the
/// hotkey" is almost always one missing grant, and the grants belong to the
/// bundle id — so renaming the app (or moving to a new signing identity) starts
/// this list from scratch.
enum TccReport {
    static func run() -> Never {
        let bundleID = Bundle.main.bundleIdentifier ?? "(unknown)"
        let path = Bundle.main.bundlePath
        emit("bundle : \(bundleID)")
        emit("path   : \(path)")
        emit("signed : \(signingIdentity() ?? "(unsigned / unreadable)")")

        // Launched from a shell, we are not our own responsible process: TCC
        // answers for the TERMINAL, which may well have Accessibility and Input
        // Monitoring already. That makes a terminal run report grants the app
        // does not have. Only `open -a Livecall --args --tcc-report` (read back
        // from the unified log) tells the truth about the bundle.
        let launchedByShell = isatty(fileno(stdout)) != 0
        emit(launchedByShell
             ? "⚠️  running from a terminal — the two keyboard grants below reflect YOUR"
             + "\n    TERMINAL, not this app. For the real state run:"
             + "\n      open -a Livecall --args --tcc-report"
             + "\n      log show --last 1m --predicate 'process == \"Livecall\"' | grep tcc-report"
             : "launched as an app bundle — the grants below are this app's own")
        emit("")

        // Read-only checks — none of these show a prompt.
        let checks: [(String, Bool, String)] = [
            ("Microphone", AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
             "your voice — the [Me] track"),
            ("Screen & System Audio Recording", CGPreflightScreenCaptureAccess(),
             "the other side — the [Them] track"),
            ("Accessibility", AXIsProcessTrusted(),
             "swallowing the hotkey before the call app sees it"),
            ("Input Monitoring", CGPreflightListenEventAccess(),
             "seeing the hotkey at all from another app"),
        ]
        for (name, granted, why) in checks {
            emit("\(granted ? "✅" : "❌") \(name.padding(toLength: 32, withPad: " ", startingAt: 0)) \(why)")
        }

        let missing = checks.filter { !$0.1 }
        emit("")
        if missing.isEmpty {
            emit("All four grants are in place.")
            exit(0)
        }
        emit("Missing \(missing.count): \(missing.map(\.0).joined(separator: ", ")).")
        emit("Grant them to THIS bundle in System Settings → Privacy & Security,")
        emit("then quit and relaunch Livecall (macOS re-reads some only at launch).")
        emit("The menu-bar item's \"Permissions & setup…\" window has direct buttons.")
        exit(1)
    }

    /// Where an `open`-launched run leaves its report (a bundle started by
    /// Launch Services has no terminal to print to).
    static let reportPath = NSHomeDirectory() + "/Library/Logs/Livecall-tcc-report.txt"
    private static var collected: [String] = []

    private static func emit(_ line: String) {
        print(line)
        collected.append(line)
        try? (collected.joined(separator: "\n") + "\n")
            .write(toFile: reportPath, atomically: true, encoding: .utf8)
    }

    private static func signingIdentity() -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &code) == errSecSuccess,
              let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        if let certs = dict["certificates"] as? [SecCertificate], let leaf = certs.first,
           let name = SecCertificateCopySubjectSummary(leaf) as String? {
            return name
        }
        return dict["identifier"] as? String
    }
}
