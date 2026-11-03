import AppKit
import ScreenCaptureKit
import UniformTypeIdentifiers

/// A silent screenshot for "answer about what's on my screen".
///
/// ScreenCaptureKit rather than the `screencapture` tool: no shutter sound, no
/// screen flash, no file dialog — and the Screen Recording grant is already
/// held for system audio, so this asks for no new permission.
///
/// WHAT it aims at matters more than how it captures. A task shown during a
/// call is nearly always shared INTO the call window, so the call app's window
/// is the tightest correct frame: it survives that window being dragged to
/// another monitor, it keeps mail and Slack out of the picture, and it is a
/// fraction of the pixels of a whole 5K display — which is latency, and latency
/// is the entire cost of this feature.
enum ScreenShot {
    enum Target {
        /// The app currently holding the mic — i.e. the call.
        case call
        /// Whatever window is frontmost, ours excluded.
        case frontmost
        /// A named display, for the case where the task is open in your own
        /// browser rather than shared into the call.
        case display(String)

        static func parse(_ spec: String) -> Target {
            let s = spec.trimmingCharacters(in: .whitespaces).lowercased()
            if s.isEmpty || s == "call" { return .call }
            if s == "front" || s == "frontmost" { return .frontmost }
            if s == "screen" || s == "display" { return .display("") }
            if s.hasPrefix("display:") { return .display(String(spec.dropFirst("display:".count))) }
            return .call
        }
    }

    enum Failure: LocalizedError {
        case nothingToCapture(String)
        var errorDescription: String? {
            switch self {
            case .nothingToCapture(let why): return why
            }
        }
    }

    /// Claude re-scales anything larger anyway, so sending a 6K retina window is
    /// paying upload time for pixels the model never sees.
    private static let maxPixels = 1400

    /// Capture, write a PNG to a temp file, return its path. The core deletes
    /// the file as soon as it has read it.
    static func capture(_ target: Target, callPIDs: [pid_t] = []) async throws -> URL {
        let content = try await SCShareableContent.excludingDesktopWindows(
            true, onScreenWindowsOnly: true)
        let mine = ProcessInfo.processInfo.processIdentifier

        let image: CGImage
        switch resolve(target, in: content, callPIDs: callPIDs, mine: mine) {
        case .window(let w):
            image = try await shoot(SCContentFilter(desktopIndependentWindow: w),
                                    width: w.frame.width, height: w.frame.height)
        case .display(let d):
            // Our own windows are excluded rather than merely ignored: the
            // answer panel floats over everything, so a full-screen grab would
            // otherwise photograph the crib sheet being written from it.
            let ours = content.applications.filter { $0.processID == mine }
            image = try await shoot(
                SCContentFilter(display: d, excludingApplications: ours, exceptingWindows: []),
                width: CGFloat(d.width), height: CGFloat(d.height))
        }
        return try writePNG(image)
    }

    // MARK: - Aim

    private enum Aim {
        case window(SCWindow)
        case display(SCDisplay)
    }

    private static func resolve(
        _ target: Target, in content: SCShareableContent, callPIDs: [pid_t], mine: pid_t
    ) -> Aim {
        switch target {
        case .call:
            if let w = biggestWindow(of: callPIDs, in: content) { return .window(w) }
            // No call detected (or it has no window — a phone dial-in, a call
            // in a browser tab we could not attribute). The screen the user is
            // looking at is the next best guess, not a failure.
            if let w = frontmostWindow(in: content, mine: mine) { return .window(w) }
            return .display(mainDisplay(in: content))
        case .frontmost:
            if let w = frontmostWindow(in: content, mine: mine) { return .window(w) }
            return .display(mainDisplay(in: content))
        case .display(let name):
            let wanted = name.trimmingCharacters(in: .whitespaces).lowercased()
            if !wanted.isEmpty,
               let d = content.displays.first(where: { displayName($0).lowercased().contains(wanted) }) {
                return .display(d)
            }
            return .display(mainDisplay(in: content))
        }
    }

    /// The call app can own several windows (the main one, a floating toolbar,
    /// a notification). The screenshare lives in the biggest.
    private static func biggestWindow(of pids: [pid_t], in content: SCShareableContent) -> SCWindow? {
        guard !pids.isEmpty else { return nil }
        return content.windows
            .filter { w in
                guard let app = w.owningApplication else { return false }
                return pids.contains(app.processID) && usable(w)
            }
            .max { $0.frame.area < $1.frame.area }
    }

    private static func frontmostWindow(in content: SCShareableContent, mine: pid_t) -> SCWindow? {
        guard let front = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              front != mine else { return nil }
        return content.windows
            .filter { $0.owningApplication?.processID == front && usable($0) }
            .max { $0.frame.area < $1.frame.area }
    }

    /// Menu-bar items, tooltips and 1x1 helper windows are not what anyone
    /// means by "my screen".
    private static func usable(_ w: SCWindow) -> Bool {
        w.isOnScreen && w.frame.width >= 200 && w.frame.height >= 200
    }

    private static func mainDisplay(in content: SCShareableContent) -> SCDisplay {
        let mainID = NSScreen.main?.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        return content.displays.first { $0.displayID == mainID } ?? content.displays[0]
    }

    private static func displayName(_ d: SCDisplay) -> String {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID)
                == d.displayID
        }?.localizedName ?? "display \(d.displayID)"
    }

    // MARK: - Shoot

    private static func shoot(_ filter: SCContentFilter, width: CGFloat, height: CGFloat) async throws -> CGImage {
        let config = SCStreamConfiguration()
        let scale = min(1, CGFloat(maxPixels) / max(width, height, 1))
        config.width = max(1, Int((width * scale).rounded()))
        config.height = max(1, Int((height * scale).rounded()))
        config.showsCursor = false
        config.captureResolution = .best
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    private static func writePNG(_ image: CGImage) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("livecall-screen-\(UUID().uuidString).png")
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw Failure.nothingToCapture("could not open a PNG destination")
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw Failure.nothingToCapture("could not write the PNG")
        }
        // The core reads and deletes it; 0600 in case it doesn't get that far.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
    }
}

private extension CGRect {
    var area: CGFloat { width * height }
}
