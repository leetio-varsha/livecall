import AVFoundation

/// Microphone -> "me" frames, via AVAudioEngine input tap.
///
/// AVAudioEngine STOPS ITSELF on a configuration change and does not throw:
/// a Bluetooth headset negotiating hands-free mode, the default input device
/// switching, a sample-rate change. After that the installed tap is stale and
/// no more buffers ever arrive — the app keeps believing the mic is on, and
/// every answer comes back "nothing was picked up".
///
/// Not hypothetical: with Bluetooth headphones as the default input, the log
/// showed this engine start recording and stop 27ms later, then stay dead for
/// hours. So the notification is observed and the tap rebuilt.
///
/// Rebuilding is itself the dangerous part. It runs *during* the handoff, when
/// the engine still reports the old device's format and the hardware already
/// answers as the new one, and `installTapOnBus` does not fail on that — it
/// RAISES. Swift cannot catch an ObjC exception, so the app died on the spot,
/// three times, the last after 75 seconds of uptime. Hence `LivecallInstallTap`
/// (see ObjC/TapInstall.h) and a retry while the device settles.
///
/// EVERY engine call in here runs on `queue`, never on the caller's thread.
/// `outputFormat(forBus:)`, `installTap`, `start()` and `stop()` all hop into
/// AVAudioEngine's own serial queues, and during a configuration change those
/// queues are busy asking CoreAudio about the device that just moved — a HAL
/// round-trip that takes seconds when the device is a Bluetooth headset in the
/// middle of switching. Rebuilding the tap on the main thread meant waiting for
/// exactly that, and the whole app froze until the headset made up its mind.
///
/// `@unchecked` because the compiler cannot see the discipline: every mutable
/// field below is either confined to `queue` or guarded by `lifecycle`.
final class MicCapture: @unchecked Sendable {
    /// How long a (re)build may take before the caller stops waiting. The work
    /// is a synchronous CoreAudio call and cannot be cancelled, so a timeout
    /// abandons this object instead of pretending it recovered — the watchdog
    /// then builds a fresh one, on a fresh queue.
    private static let buildTimeout: TimeInterval = 8
    /// A single device handoff posts several notifications in a row. Rebuilding
    /// on each one keeps the audio queues busy, which is what makes the next
    /// rebuild slow, so the burst is collapsed into one.
    private static let coalesceDelay: TimeInterval = 0.25
    /// A configuration change is not an event, it is a settling process: the
    /// HAL is still rebuilding its aggregate device, and an engine built in
    /// that window can be handed a format the hardware has already left, which
    /// `installTap` refuses. So a refused attempt is retried while the device
    /// settles — backing off, never blocking `queue`. Four attempts spread over
    /// 2.8s, which stays inside the watchdog's 8s stall threshold: if this
    /// cannot recover, the slow path should get its turn rather than be raced.
    private static let rebuildAttempts = 4
    private static let firstRetryDelay: TimeInterval = 0.4

    /// Replaced on every rebuild, never restarted — see `replaceEngine()`.
    private var engine = AVAudioEngine()
    private let converter = PCMConverter { data in
        FrameWriter.shared.write(source: 0, data)
    }
    /// The only thread allowed to talk to `engine`.
    private let queue = DispatchQueue(label: "org.leetio.livecall.mic")
    /// Timeouts fire here, because `queue` is the thing that might be stuck.
    private let timers = DispatchQueue(label: "org.leetio.livecall.mic.timeout")

    /// Guards the two fields `stop()` has to set from the caller's thread. It
    /// cannot set them on `queue`, because `queue` being wedged on a device
    /// that will not answer is the very case where teardown matters: a capture
    /// that only learns it was stopped once its queue drains goes on
    /// subscribing to notifications and rebuilding itself in the meantime.
    private let lifecycle = NSLock()
    private var observer: NSObjectProtocol?
    private var stopped = false
    // Everything below is touched only on `queue`.
    private var pendingRebuild: DispatchWorkItem?
    private var installedFormat: AVAudioFormat?

    private var isStopped: Bool {
        lifecycle.lock(); defer { lifecycle.unlock() }
        return stopped
    }

    /// Suspends the caller rather than blocking its thread — on the main actor
    /// that is the difference between a busy audio device and a frozen app.
    func start() async throws {
        try await onQueue {
            try self.installAndStart()
            self.watchForConfigurationChanges(on: self.engine)
        }
    }

    /// Returns immediately. Teardown talks to CoreAudio too, and the callers —
    /// app quit, or the watchdog swapping in a new capture — must not block on
    /// a device that is busy disappearing.
    func stop() {
        // Before the queue hop, not on it: this is what makes an abandoned
        // capture stop reacting even when its queue never drains again.
        lifecycle.lock()
        stopped = true
        let last = observer
        observer = nil
        lifecycle.unlock()
        if let last { NotificationCenter.default.removeObserver(last) }

        // Strong capture on purpose: the caller drops its reference right after
        // this call, and the tap must still come off in an orderly way.
        queue.async {
            self.pendingRebuild?.cancel()
            self.pendingRebuild = nil
            self.engine.inputNode.removeTap(onBus: 0)
            self.engine.stop()
            self.installedFormat = nil
        }
    }

    /// The notification is per-engine, so every engine this capture builds has
    /// to be subscribed to in turn, and the previous subscription dropped.
    private func watchForConfigurationChanges(on eng: AVAudioEngine) {
        let token = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: eng,
            // Deliberately no queue. `.main` is what froze the UI, and hopping
            // to an OperationQueue would still run engine calls somewhere we do
            // not control. The block runs on whichever thread posted — so it
            // only schedules, and returns immediately.
            queue: nil
        ) { [weak self] _ in
            self?.scheduleRebuild()
        }

        lifecycle.lock()
        let previous = observer
        // A `stop()` that landed while this engine was being built wins: the
        // subscription is dropped again rather than outliving the capture.
        if stopped {
            lifecycle.unlock()
            NotificationCenter.default.removeObserver(token)
            return
        }
        observer = token
        lifecycle.unlock()
        if let previous { NotificationCenter.default.removeObserver(previous) }
    }

    // MARK: - Rebuilding

    private func scheduleRebuild() {
        queue.async { [weak self] in
            guard let self, !self.isStopped else { return }
            self.pendingRebuild?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.rebuild() }
            self.pendingRebuild = work
            self.queue.asyncAfter(deadline: .now() + Self.coalesceDelay, execute: work)
        }
    }

    private func rebuild(attempt: Int = 0) {
        guard !isStopped else { return }
        // Starting the engine can itself post a configuration change, so acting
        // on every notification loops. What actually matters is whether the tap
        // still carries the current device's format — if it does, and the engine
        // is running, nothing moved and there is nothing to rebuild.
        let current = engine.inputNode.outputFormat(forBus: 0)
        if engine.isRunning, let installed = installedFormat,
           current.sampleRate == installed.sampleRate,
           current.channelCount == installed.channelCount {
            return
        }
        do {
            replaceEngine()
            try installAndStart()
            NSLog("mic: audio configuration changed — engine rebuilt at %.0fHz",
                  installedFormat?.sampleRate ?? 0)
        } catch {
            let next = attempt + 1
            guard next < Self.rebuildAttempts else {
                // The core's watchdog still sees frames stop and asks for a full
                // rebuild — a whole new MicCapture on a new engine, which is what
                // cures a device that never settled. This is the fast path, not
                // the only one.
                NSLog("mic: rebuild after configuration change failed %d times, leaving it to the watchdog: %@",
                      next, error.localizedDescription)
                return
            }
            // Reusing pendingRebuild on purpose: a fresh configuration change
            // cancels this chain and starts its own, rather than racing it.
            let work = DispatchWorkItem { [weak self] in self?.rebuild(attempt: next) }
            pendingRebuild = work
            queue.asyncAfter(deadline: .now() + Self.firstRetryDelay * pow(2, Double(attempt)),
                             execute: work)
        }
    }

    /// Throws the old engine away and starts listening on a new one.
    ///
    /// Reinstalling the tap on the existing engine does not work, and not
    /// merely in the racy window: an engine pins its input format when it is
    /// created and never lets go. Measured, with the engine brought up on the
    /// built-in mic and a Bluetooth headset then taking the input over — the
    /// engine kept answering 44100Hz while the hardware was 16000Hz, so every
    /// one of the four attempts was refused for the mismatch, and the mic
    /// stayed at 0 B/s for the whole 15s it was watched. A new engine binds to
    /// the device that is actually there: full rate within five seconds, the
    /// same as one that had been created on the headset to begin with.
    ///
    /// The new engine is subscribed to before the tap goes on, so that a
    /// handoff arriving mid-rebuild is still noticed.
    private func replaceEngine() {
        dispatchPrecondition(condition: .onQueue(queue))
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        installedFormat = nil
        engine = AVAudioEngine()
        watchForConfigurationChanges(on: engine)
    }

    /// Reinstalling the tap is not optional after a configuration change: the
    /// old one carries the previous device's format.
    private func installAndStart() throws {
        dispatchPrecondition(condition: .onQueue(queue))
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        installedFormat = nil

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        // With no usable input device the format comes back at 0Hz, and
        // installTap traps on it rather than throwing. Refuse instead.
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "livecall.mic", code: 1, userInfo: [
                NSLocalizedDescriptionKey:
                    "no usable audio input (\(format.sampleRate)Hz/\(format.channelCount)ch) — check the input device",
            ])
        }
        // Through the ObjC shim, because this call raises rather than fails:
        // the format read a line ago is what AVAudioEngine believes, and mid
        // handoff that is not yet what the hardware is. See TapInstall.h.
        if let raised = LivecallInstallTap(input, 0, 4096, format, { [converter] buf, _ in
            converter.push(buf)
        }) {
            throw raised
        }
        engine.prepare()
        try engine.start()
        installedFormat = format
    }

    // MARK: - Bridging to the engine queue

    /// Runs `body` on `queue` and gives up waiting after `buildTimeout`. Giving
    /// up does not cancel the work — a synchronous CoreAudio call cannot be
    /// cancelled — so the object tears itself down instead of being left half
    /// alive, with a tap nobody remembers installing.
    private func onQueue(_ body: @escaping () throws -> Void) async throws {
        let gate = ResumeGate()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    try body()
                    gate.resume(cont, .success(()))
                } catch {
                    gate.resume(cont, .failure(error))
                }
            }
            timers.asyncAfter(deadline: .now() + Self.buildTimeout) {
                let timedOut = gate.resume(cont, .failure(NSError(
                    domain: "livecall.mic", code: 2, userInfo: [
                        NSLocalizedDescriptionKey:
                            "audio input did not answer in \(Int(Self.buildTimeout))s — device is wedged",
                    ])))
                if timedOut { self.stop() }
            }
        }
    }
}

/// A continuation may be resumed exactly once — twice traps — and two racers
/// reach this one: the engine call finishing, and the timeout firing.
///
/// `@unchecked` because the one piece of state is guarded by the lock beside it.
private final class ResumeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false

    /// True if this caller was the one that resumed.
    @discardableResult
    func resume(_ cont: CheckedContinuation<Void, Error>, _ result: Result<Void, Error>) -> Bool {
        lock.lock()
        let first = !used
        used = true
        lock.unlock()
        if first { cont.resume(with: result) }
        return first
    }
}
