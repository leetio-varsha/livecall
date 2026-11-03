import Foundation
import CoreGraphics
import ApplicationServices

/// Global hotkeys via a CGEventTap: press them in Zoom / Meet / anywhere and
/// the core answers, without switching to Livecall.
///
/// Two kinds:
///   • COMBO  — modifiers + a key, e.g. ⌥⌘A. Swallowed, so the call app never
///              sees it.
///   • TAP    — a lone modifier pressed and released on its own, e.g. the right
///              ⌥. One key, reachable without looking. NEVER swallowed: eating
///              a modifier would break ⌥+letter symbol input system-wide, so
///              the event is always passed through and we only *observe* it.
///
/// A tap only counts when the modifier goes down and back up with nothing in
/// between — no keystroke, no click, no scroll — and within `tapMaxHold`. So
/// holding ⌥ as a modifier, ⌥-clicking, or ⌥-scrolling never fires it.
///
/// PRIVACY: an active tap is handed every key and mouse-down in the login
/// session before the focused app sees it. This callback does the absolute
/// minimum: compare keycode + modifier bits, and for keys/clicks/scrolls set a
/// single "the modifier was used for something" flag. Nothing is read as text,
/// no coordinates, no buffering, no logging — the only thing that leaves this
/// file is "fast"/"deep".
final class HotkeyTap {
    private let combos: [HotkeyCombo]
    private let taps: [ModifierTap]
    private let onHotkey: (String) -> Void

    /// A lone-modifier press held longer than this is a modifier, not a tap.
    private let tapMaxHold: TimeInterval = 0.4
    /// Ignore a repeat of the same trigger inside this window (key bounce).
    private let debounce: TimeInterval = 0.4

    private var tap: CFMachPort?
    private var lastFire: [String: TimeInterval] = [:]

    // Tap state machine.
    private var previousFlags: UInt64 = 0
    private var candidateDevice: UInt64 = 0      // 0 = no tap in progress
    private var candidateAt: TimeInterval = 0
    private var candidateUsed = false            // a key/click/scroll intervened

    init(combos: [HotkeyCombo], taps: [ModifierTap], onHotkey: @escaping (String) -> Void) {
        self.combos = combos
        self.taps = taps
        self.onHotkey = onHotkey
    }

    /// Installs the tap on a dedicated thread with its own run loop (the main
    /// thread is parked in async sleep, and capture callbacks own their queues).
    /// Returns false when macOS refused the tap — almost always a missing
    /// Accessibility / Input Monitoring grant.
    @discardableResult
    func start() -> Bool {
        requestPermissions()
        let ready = DispatchSemaphore(value: 0)
        var created = false
        let thread = Thread { [weak self] in
            guard let self else {
                ready.signal()
                return
            }
            created = self.createTap()
            ready.signal()
            if created { RunLoop.current.run() }
        }
        thread.name = "org.leetio.livecall.hotkey"
        thread.start()
        ready.wait()
        return created
    }

    private func createTap() -> Bool {
        var mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        if !taps.isEmpty {
            // flagsChanged drives tap detection. The mouse and scroll events are
            // watched ONLY to notice that the held modifier was used for
            // something (⌥-click, ⌥-scroll) so we don't fire on release.
            for type in [CGEventType.flagsChanged, .leftMouseDown, .rightMouseDown,
                         .otherMouseDown, .scrollWheel] {
                mask |= CGEventMask(1 << type.rawValue)
            }
        }
        guard
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap, // active: lets us swallow our own combo
                eventsOfInterest: mask,
                callback: hotkeyTapCallback,
                userInfo: Unmanaged.passUnretained(self).toOpaque())
        else {
            return false
        }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // macOS kills a tap whose callback was too slow (or on a user switch);
        // it stays dead until re-enabled, so the hotkey would silently stop.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            log("hotkey tap was disabled by the system — re-enabled")
            return nil
        }

        switch type {
        case .flagsChanged:
            handleFlagsChanged(event)
            return Unmanaged.passUnretained(event) // never swallow a modifier
        case .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel:
            candidateUsed = true // ⌥-click / ⌥-scroll: not a tap
            return Unmanaged.passUnretained(event)
        case .keyDown:
            candidateUsed = true // the modifier is being used as a modifier
            return handleKeyDown(event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func handleKeyDown(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        guard event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else {
            return Unmanaged.passUnretained(event)
        }
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        // Only these four count — caps lock, fn and device-dependent bits must
        // not break the match.
        let mods = event.flags.intersection([.maskCommand, .maskAlternate, .maskShift, .maskControl])
        guard let combo = combos.first(where: { $0.keyCode == keyCode && $0.mods == mods }) else {
            return Unmanaged.passUnretained(event)
        }
        fire(combo.mode)
        return nil // swallow — the call app must not also receive our shortcut
    }

    /// Tap detection. `flagsChanged` reports the modifier state AFTER the
    /// change, and its device-dependent bits say which physical key moved —
    /// that's how left and right ⌥ are told apart.
    private func handleFlagsChanged(_ event: CGEvent) {
        let flags = event.flags.rawValue
        defer { previousFlags = flags }

        for candidate in taps {
            let bit = candidate.deviceBit
            let wasDown = previousFlags & bit != 0
            let isDown = flags & bit != 0
            if isDown, !wasDown {
                // Pressed. Only a candidate if no other modifier was already
                // down — ⇧ is allowed, it selects the mode.
                let otherModifiers = flags & ModifierTap.allDeviceBits & ~bit & ~ModifierTap.shiftBits
                candidateDevice = otherModifiers == 0 ? bit : 0
                candidateAt = Date().timeIntervalSinceReferenceDate
                candidateUsed = false
                return
            }
            if wasDown, !isDown {
                // Released. Read ⇧ from the flags BEFORE this change: at
                // release time the state we care about is "was shift held
                // while the key was down".
                let shiftHeld = previousFlags & ModifierTap.shiftBits != 0
                let held = Date().timeIntervalSinceReferenceDate - candidateAt
                let clean = candidateDevice == bit && !candidateUsed && held < tapMaxHold
                candidateDevice = 0
                guard clean else { return }
                if let match = taps.first(where: {
                    $0.deviceBit == bit && $0.requiresShift == shiftHeld
                }) {
                    fire(match.mode)
                }
                return
            }
        }
    }

    private func fire(_ mode: String) {
        let now = Date().timeIntervalSinceReferenceDate
        if now - (lastFire[mode] ?? 0) < debounce { return }
        lastFire[mode] = now
        onHotkey(mode)
    }

    /// Both grants matter: Input Monitoring to see keys at all, Accessibility
    /// to run an active (event-swallowing) tap. Prompts are no-ops once granted.
    private func requestPermissions() {
        if !CGPreflightListenEventAccess() {
            log("requesting Input Monitoring access…")
            _ = CGRequestListenEventAccess()
        }
        if !AXIsProcessTrusted() {
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
            log("Accessibility access is not granted yet — approve the dialog, then restart Livecall")
        }
    }
}

/// C callback: no captures allowed, so `self` travels through userInfo.
private let hotkeyTapCallback: CGEventTapCallBack = { _, type, event, refcon in
    guard let refcon else { return Unmanaged.passUnretained(event) }
    return Unmanaged<HotkeyTap>.fromOpaque(refcon).takeUnretainedValue().handle(type: type, event: event)
}

/// Turns `.env`-style specs into armed hotkeys. Shared by the CLI helper and
/// the app so a spec means the same thing in both.
enum HotkeySpecs {
    struct Parsed {
        var combos: [HotkeyCombo] = []
        var taps: [ModifierTap] = []
        var labels: [String] = []
        var bad: [String] = []
        var isEmpty: Bool { combos.isEmpty && taps.isEmpty }
        /// Label for one mode, for menus and logs.
        func label(for mode: String) -> String? {
            taps.first { $0.mode == mode }?.label ?? combos.first { $0.mode == mode }?.label
        }
    }

    /// A tap spec wins over a combo spec — "ropt" is only ever a tap.
    static func parse(_ specs: [(mode: String, spec: String)]) -> Parsed {
        var out = Parsed()
        for (mode, spec) in specs {
            if let tap = ModifierTap.parse(spec, mode: mode) {
                out.taps.append(tap)
                out.labels.append("\(tap.label) = \(mode)")
            } else if let combo = HotkeyCombo.parse(spec, mode: mode) {
                out.combos.append(combo)
                out.labels.append("\(combo.label) = \(mode)")
            } else {
                out.bad.append("\(spec) (\(mode))")
            }
        }
        return out
    }
}

/// A lone modifier tapped on its own — one key, no chord.
struct ModifierTap {
    let mode: String        // "fast" | "deep" — goes verbatim into the control frame
    let deviceBit: UInt64   // which physical modifier (NX_DEVICE*KEYMASK)
    let requiresShift: Bool
    let label: String       // "right ⌥", for the startup log

    // Device-dependent modifier bits (IOKit's NX_DEVICE*KEYMASK). CGEventFlags
    // only says "some ⌥ is down"; these say which side.
    private static let devices: [String: (bit: UInt64, name: String)] = [
        "ropt": (0x40, "right ⌥"), "rightopt": (0x40, "right ⌥"), "rightoption": (0x40, "right ⌥"),
        "lopt": (0x20, "left ⌥"), "leftopt": (0x20, "left ⌥"), "leftoption": (0x20, "left ⌥"),
        "rcmd": (0x10, "right ⌘"), "rightcmd": (0x10, "right ⌘"), "rightcommand": (0x10, "right ⌘"),
        "lcmd": (0x08, "left ⌘"), "leftcmd": (0x08, "left ⌘"), "leftcommand": (0x08, "left ⌘"),
        "rctrl": (0x2000, "right ⌃"), "rightctrl": (0x2000, "right ⌃"),
    ]
    static let shiftBits: UInt64 = 0x02 | 0x04            // left | right ⇧
    /// Every device bit we know about — used to tell "modifier alone" from
    /// "modifier as part of a chord".
    static let allDeviceBits: UInt64 = 0x01 | 0x02 | 0x04 | 0x08 | 0x10 | 0x20 | 0x40 | 0x2000

    /// Parses "ropt" / "shift+ropt". Returns nil if this isn't a tap spec, so
    /// the caller can fall through to combo parsing.
    static func parse(_ spec: String, mode: String) -> ModifierTap? {
        var wantsShift = false
        var device: (bit: UInt64, name: String)?
        for part in spec.lowercased().split(separator: "+").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            switch part {
            case "": continue
            case "shift", "⇧": wantsShift = true
            default:
                guard device == nil, let d = devices[part] else { return nil }
                device = d
            }
        }
        guard let device else { return nil }
        return ModifierTap(
            mode: mode, deviceBit: device.bit, requiresShift: wantsShift,
            label: (wantsShift ? "⇧ + " : "") + device.name + " tap")
    }
}

/// One parsed combo hotkey: which keys, and which answer mode it triggers.
struct HotkeyCombo {
    let mode: String // "fast" | "deep" — goes verbatim into the control frame
    let keyCode: CGKeyCode
    let mods: CGEventFlags
    let label: String // "⌥⌘A", for the startup log

    private static let modNames: [String: CGEventFlags] = [
        "cmd": .maskCommand, "command": .maskCommand, "⌘": .maskCommand,
        "opt": .maskAlternate, "option": .maskAlternate, "alt": .maskAlternate, "⌥": .maskAlternate,
        "shift": .maskShift, "⇧": .maskShift,
        "ctrl": .maskControl, "control": .maskControl, "⌃": .maskControl,
    ]

    /// ANSI virtual keycodes (Carbon kVK_ANSI_*), enough for letter/digit combos.
    private static let keyCodes: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "o": 31, "u": 32,
        "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
        "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22, "7": 26, "8": 28, "9": 25, "0": 29,
        "space": 49, "return": 36, "enter": 36, "tab": 48, "escape": 53, "esc": 53,
        "-": 27, "=": 24, "[": 33, "]": 30, ";": 41, "'": 39, ",": 43, ".": 47, "/": 44, "`": 50,
        "f13": 105, "f14": 107, "f15": 113, "f16": 106, "f17": 64, "f18": 79, "f19": 80,
    ]

    /// Parses "opt+cmd+a" / "⇧⌥⌘A" style specs. Returns nil on anything it
    /// doesn't understand — a typo must not silently arm the wrong key.
    static func parse(_ spec: String, mode: String) -> HotkeyCombo? {
        let parts = spec.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        guard !parts.isEmpty else { return nil }

        var mods: CGEventFlags = []
        var key: CGKeyCode?
        var keyName = ""
        for part in parts where !part.isEmpty {
            if let mod = modNames[part] {
                mods.insert(mod)
            } else if let code = keyCodes[part], key == nil {
                key = code
                keyName = part
            } else {
                return nil // unknown token, or a second non-modifier key
            }
        }
        guard let key else { return nil }
        // A bare letter would eat normal typing. The F13–F19 block is safe
        // alone — those keys type nothing.
        let standalone = key >= 64 && key <= 113
        guard !mods.isEmpty || standalone else { return nil }

        // Apple's canonical modifier order: ⌃⌥⇧⌘
        var label = ""
        if mods.contains(.maskControl) { label += "⌃" }
        if mods.contains(.maskAlternate) { label += "⌥" }
        if mods.contains(.maskShift) { label += "⇧" }
        if mods.contains(.maskCommand) { label += "⌘" }
        return HotkeyCombo(mode: mode, keyCode: key, mods: mods, label: label + keyName.uppercased())
    }
}
