import Foundation

/// Binary frame protocol (little-endian):
///   byte 0     : source — 0 = me (mic), 1 = them (system audio), 2 = control
///   bytes 1..3 : reserved (0)
///   bytes 4..7 : UInt32 payload length
///   payload    : s16le 16kHz mono PCM for sources 0/1, UTF-8 JSON for control
///
/// The CLI helper writes these to stdout for the core to read; Livecall.app
/// writes the very same frames into the core's stdin — hence the settable
/// destination. All writes are serialized on one queue so frames never
/// interleave, and a vanished reader can't take the process down with it.
final class FrameWriter {
    static let shared = FrameWriter()
    private let queue = DispatchQueue(label: "org.leetio.livecall.frames")
    private var out = FileHandle.standardOutput
    private var broken = false

    /// Send frames somewhere else from now on (e.g. the core's stdin).
    func setOutput(_ handle: FileHandle) {
        queue.async {
            self.out = handle
            self.broken = false
        }
    }

    func write(source: UInt8, _ payload: Data) {
        queue.async {
            guard !self.broken else { return }
            var frame = Data(capacity: 8 + payload.count)
            frame.append(source)
            frame.append(contentsOf: [0, 0, 0])
            var len = UInt32(payload.count).littleEndian
            withUnsafeBytes(of: &len) { frame.append(contentsOf: $0) }
            frame.append(payload)
            do {
                try self.out.write(contentsOf: frame)
            } catch {
                // The reader is gone (core exited). Stop writing rather than
                // die on EPIPE — the owner decides what to do about it.
                self.broken = true
                log("frame sink closed: \(error.localizedDescription)")
            }
        }
    }

    /// Control frame: `{"event":"call_start"}`, `{"event":"hotkey","mode":"fast"}`.
    func writeControl(_ event: String, _ fields: [String: String] = [:]) {
        var payload = fields
        payload["event"] = event
        let json = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
        write(source: 2, json)
    }
}

func log(_ s: String) {
    FileHandle.standardError.write(Data("[helper] \(s)\n".utf8))
}
