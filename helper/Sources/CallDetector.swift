import Foundation
import CoreAudio
import Darwin
import os

/// Detects when a call is happening by watching whether any process *other
/// than us* is using audio input. Adapted from the Echo dictation app
/// (https://github.com/leetio-varsha/echo), including its replayd/corespeechd
/// false-positive fixes; only the timer queue and log subsystem changed.
///
/// Uses the per-process Core Audio HAL (macOS 14.4+). A process only counts
/// as a call if it runs input on an actual input DEVICE — tap-based listeners
/// (corespeechd analyzing media playback) report no input device.
final class CallDetector {
    var onCallStart: (() -> Void)?
    var onCallEnd: (() -> Void)?

    private let myPID = ProcessInfo.processInfo.processIdentifier
    /// Our own executable name, so a SECOND copy of us isn't mistaken for a call.
    /// Excluding just `myPID` isn't enough: during a rebuild-and-relaunch the old
    /// instance is briefly still on the mic, the new one sees it as a call start
    /// and wipes the running Q&A session. Observed 2026-07-31 10:11:57 —
    /// `Livecall[46656] … mic held by: Livecall(48375)`. Derived from the running
    /// process rather than hardcoded, so it survives a rename.
    private let myName: String = CallDetector.processName(ProcessInfo.processInfo.processIdentifier)
    private let log = Logger(subsystem: "org.leetio.livecall", category: "detect")
    // Daemons spun up by our OWN capture (ScreenCaptureKit -> replayd) show as
    // mic-input processes and never release; they aren't "calls". Neither is
    // Echo, a dictation app that sits on the mic permanently when installed —
    // without this, every Echo recording would look like a new call and wipe
    // the running Q&A session. Extend with DETECT_EXCLUDE.
    private var excludedNames: Set<String> = ["replayd", "coreaudiod", "corespeechd", "Echo"]
    private let pollInterval: TimeInterval = 2
    private let endDebounce: TimeInterval = 5 // mic must stay free this long to end a call

    private let queue = DispatchQueue(label: "org.leetio.livecall.detect")
    private var timer: DispatchSourceTimer?
    private var callActive = false
    private var freeSince: Date?
    /// Who is currently holding the mic besides us. Read by the screenshot:
    /// a task shown during a call is nearly always shared INTO the call app's
    /// window, so this is the thing worth aiming the camera at.
    private var callPIDsLock = NSLock()
    private var callPIDs: [pid_t] = []

    /// PIDs of the apps on the mic right now, freshest poll. Safe to call from
    /// any thread.
    var currentCallPIDs: [pid_t] {
        callPIDsLock.lock()
        defer { callPIDsLock.unlock() }
        return callPIDs
    }

    /// Additional process names that must never count as a call.
    func exclude(_ names: [String]) {
        excludedNames.formUnion(names.filter { !$0.isEmpty })
    }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: pollInterval)
        t.setEventHandler { [weak self] in self?.poll() }
        timer = t
        t.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
        callActive = false
        freeSince = nil
    }

    private func poll() {
        let others = otherMicInputPIDs()
        callPIDsLock.lock()
        callPIDs = others
        callPIDsLock.unlock()
        if !others.isEmpty {
            freeSince = nil
            if !callActive {
                callActive = true
                let who = others.map { "\(Self.processName($0))(\($0))" }.joined(separator: ", ")
                log.notice("call auto-detected — mic held by: \(who, privacy: .public)")
                onCallStart?()
            }
        } else if callActive {
            if freeSince == nil {
                freeSince = Date()
            } else if Date().timeIntervalSince(freeSince!) >= endDebounce {
                callActive = false
                freeSince = nil
                onCallEnd?()
            }
        }
    }

    /// PIDs of audio processes other than us that currently have input running.
    private func otherMicInputPIDs() -> [pid_t] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)

        var size: UInt32 = 0
        let sys = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(sys, &addr, 0, nil, &size) == noErr, size > 0 else {
            return []
        }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var procs = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(sys, &addr, 0, nil, &size, &procs) == noErr else {
            return []
        }

        var result: [pid_t] = []
        for proc in procs {
            let pid = processPID(proc)
            if pid == myPID { continue }
            let name = Self.processName(pid)
            // Another copy of us (rebuild-and-relaunch overlap) is not a call.
            if !myName.isEmpty, name == myName { continue }
            if excludedNames.contains(name) { continue }
            guard processInputRunning(proc) else { continue }
            // Tap-based listeners run input with NO input device attached — not a call.
            guard !processInputDevices(proc).isEmpty else { continue }
            result.append(pid)
        }
        return result
    }

    /// Devices `proc` currently runs INPUT on (input scope — the global scope
    /// returns [] even for real mic users). Empty for AudioTap-fed processes.
    private func processInputDevices(_ proc: AudioObjectID) -> [AudioObjectID] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyDevices,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(proc, &addr, 0, nil, &size) == noErr, size > 0 else {
            return []
        }
        var devs = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(proc, &addr, 0, nil, &size, &devs) == noErr else {
            return []
        }
        return devs
    }

    private static func processName(_ pid: pid_t) -> String {
        guard pid > 0 else { return "" }
        var buf = [CChar](repeating: 0, count: 256)
        let n = proc_name(pid, &buf, UInt32(buf.count))
        return n > 0 ? String(cString: buf) : ""
    }

    private func processPID(_ proc: AudioObjectID) -> pid_t {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var pid: pid_t = -1
        var size = UInt32(MemoryLayout<pid_t>.size)
        _ = AudioObjectGetPropertyData(proc, &addr, 0, nil, &size, &pid)
        return pid
    }

    private func processInputRunning(_ proc: AudioObjectID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningInput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(proc, &addr, 0, nil, &size, &running) == noErr else {
            return false
        }
        return running != 0
    }
}
