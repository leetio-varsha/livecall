import Foundation

/// The helper is spawned by the core and has no reason to outlive it. If the
/// core dies without cleaning up (terminal window closed, SIGKILL, crash),
/// macOS reparents us to launchd and we would keep holding the microphone, the
/// system-audio capture and — worst of all — the keyboard tap, which would go
/// on swallowing ⌥⌘A system-wide with nobody left to answer.
enum ParentWatchdog {
    private static var timer: DispatchSourceTimer?

    static func start() {
        let parent = getppid()
        // Already parentless (launched by launchd / from an .app bundle):
        // there is nothing meaningful to watch.
        guard parent > 1 else { return }

        let t = DispatchSource.makeTimerSource(
            queue: DispatchQueue(label: "org.leetio.livecall.watchdog"))
        t.schedule(deadline: .now() + 2, repeating: 2)
        t.setEventHandler {
            guard getppid() != parent else { return }
            log("core process is gone — releasing mic, system audio and hotkeys")
            exit(0)
        }
        timer = t
        t.resume()
    }
}
