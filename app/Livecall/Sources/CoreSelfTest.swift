import Foundation

/// `Livecall --core-selftest` — headless check of the app↔core wiring:
/// spawn the Node core, wait for `ready`, ask one question through the same
/// control frame the menu uses, and print what comes back. No menu bar, no
/// capture, no permissions involved — so it answers "is the core reachable?"
/// separately from "did macOS give us the microphone?".
enum CoreSelfTest {
    static func run() -> Never {
        let core = CoreProcess()
        let done = DispatchSemaphore(value: 0)
        var answer = ""
        var ok = false
        var failure: String?

        core.onLog = { FileHandle.standardError.write(Data("[core] \($0)\n".utf8)) }
        core.onExit = { code in
            if !ok {
                failure = failure ?? "core exited with \(code) before answering"
                done.signal()
            }
        }
        core.onEvent = { event in
            switch event.type {
            case "ready":
                print("✅ core ready in \(event.int("loadMs") ?? -1) ms " +
                      "(backend \(event.string("backend") ?? "?"), model \(event.string("model") ?? "?"))")
                print("→ asking one FAST question through a control frame…")
                core.send("ask", ["mode": "fast"])
            case "ask_start":
                print("✅ core accepted the ask (\(event.string("mode") ?? "?"))")
            case "first_token":
                print("✅ first token after \(event.int("ms") ?? -1) ms")
            case "answer_delta":
                answer += event.string("text") ?? ""
            case "answer_done":
                print("✅ answer complete in \(event.int("totalMs") ?? -1) ms")
                ok = true
                done.signal()
            case "answer_error", "fatal":
                failure = event.string("message") ?? event.type
                done.signal()
            default:
                break
            }
        }

        do {
            try core.start(repoRoot: BuildConfig.repoRoot)
        } catch {
            print("❌ \(error.localizedDescription)")
            exit(1)
        }

        if done.wait(timeout: .now() + 180) == .timedOut {
            failure = "timed out after 180s"
        }
        core.stop()

        if ok {
            print("\n--- answer ---\n\(answer.prefix(400))\n")
            print("RESULT: ✅ app ↔ core wiring works")
            exit(0)
        }
        print("RESULT: ❌ \(failure ?? "unknown failure")")
        exit(1)
    }
}
