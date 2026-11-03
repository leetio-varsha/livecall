import Foundation

/// One JSON event from the core (`core/src/ipc.ts`), already decoded.
struct CoreEvent {
    let type: String
    let fields: [String: Any]

    func string(_ key: String) -> String? { fields[key] as? String }
    func int(_ key: String) -> Int? { (fields[key] as? NSNumber)?.intValue }
}

/// Owns the Node core: spawns it, streams audio + control frames into its
/// stdin, and turns its line-delimited stdout into CoreEvents.
final class CoreProcess {
    var onEvent: ((CoreEvent) -> Void)?
    var onExit: ((Int32) -> Void)?
    var onLog: ((String) -> Void)?

    private var proc: Process?
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private var lineBuffer = Data()

    var isRunning: Bool { proc?.isRunning ?? false }

    func start(repoRoot: String) throws {
        let core = "\(repoRoot)/core"
        let node = try resolveNode()

        let p = Process()
        p.executableURL = URL(fileURLWithPath: node)
        p.arguments = ["src/ipc.ts"]
        p.currentDirectoryURL = URL(fileURLWithPath: core)

        // A Finder-launched app inherits a minimal PATH; the core spawns
        // whisper-server and possibly the claude CLI by name.
        var env = ProcessInfo.processInfo.environment
        if let path = loginShellPath(), !path.isEmpty { env["PATH"] = path }
        p.environment = env

        p.standardInput = stdinPipe
        p.standardOutput = stdoutPipe
        p.standardError = stderrPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            if data.isEmpty { return }
            self?.consume(data)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            self?.onLog?(text.trimmingCharacters(in: .newlines))
        }
        p.terminationHandler = { [weak self] proc in
            self?.stdoutPipe.fileHandleForReading.readabilityHandler = nil
            self?.stderrPipe.fileHandleForReading.readabilityHandler = nil
            self?.onExit?(proc.terminationStatus)
        }

        try p.run()
        proc = p
        // Capture code writes frames straight into the core from now on.
        FrameWriter.shared.setOutput(stdinPipe.fileHandleForWriting)
    }

    func send(_ event: String, _ fields: [String: String] = [:]) {
        FrameWriter.shared.writeControl(event, fields)
    }

    /// Closing stdin is how ipc.ts is asked to shut down cleanly.
    func stop() {
        guard let p = proc, p.isRunning else { return }
        send("quit")
        try? stdinPipe.fileHandleForWriting.close()
        // Don't wait forever on a wedged core.
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if p.isRunning { p.terminate() }
        }
    }

    private func consume(_ data: Data) {
        lineBuffer.append(data)
        while let nl = lineBuffer.firstIndex(of: 0x0A) {
            let line = lineBuffer[lineBuffer.startIndex..<nl]
            lineBuffer.removeSubrange(lineBuffer.startIndex...nl)
            guard !line.isEmpty,
                  let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let type = obj["type"] as? String
            else { continue }
            onEvent?(CoreEvent(type: type, fields: obj))
        }
    }

    /// Resolve `node` and the login PATH through a login shell, so homebrew /
    /// nvm installs are found when the app is launched from Finder.
    private func resolveNode() throws -> String {
        guard let path = shell("command -v node"), !path.isEmpty,
              FileManager.default.isExecutableFile(atPath: path)
        else {
            throw CoreError.nodeNotFound
        }
        return path
    }

    private func loginShellPath() -> String? { shell("printf %s \"$PATH\"") }

    private func shell(_ command: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", command]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum CoreError: LocalizedError {
    case nodeNotFound
    var errorDescription: String? {
        "Couldn't find `node`. Install Node ≥ 22 (strip-only TypeScript) or fix your shell PATH."
    }
}
