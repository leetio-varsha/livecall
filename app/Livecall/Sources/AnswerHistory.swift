import Foundation

/// One answered question, kept after the next hotkey press pushes it off screen.
///
/// Until this existed the previous answer was destroyed on the next press
/// (`answer = ""`), which is the wrong trade in a live call: the half of an
/// answer you actually needed is often the half you only recognise two
/// questions later.
struct AnswerRecord: Identifiable, Codable {
    let id: UUID
    let at: Date
    /// "fast" | "deep", verbatim from the control frame.
    let mode: String
    /// What was heard when the hotkey was pressed. The only thing that tells
    /// two answers apart at a glance, so it doubles as this entry's title.
    var question: String
    var header: String
    var text: String
    /// First answer of a call. Marked so that paging back through history never
    /// silently crosses into a different conversation.
    var startsCall: Bool

    init(mode: String, question: String, header: String, startsCall: Bool) {
        self.id = UUID()
        self.at = Date()
        self.mode = mode
        self.question = question
        self.header = header
        self.text = ""
        self.startsCall = startsCall
    }
}

/// Append-only JSONL log of answers, one record per line.
///
/// Lives in Application Support, never in the repo: these are the actual
/// answers given on real calls, and that is not something to leave sitting in a
/// working tree waiting to be committed. The file is 0600 and the menu wipes it.
///
/// One line per record, appended and flushed as each answer completes, so a
/// crash mid-call costs at most the answer being written — and so the log can
/// be tailed while a call is still running.
final class AnswerHistoryStore {
    private let url: URL
    /// Writes never touch the calling thread: this runs during a live call.
    private let queue = DispatchQueue(label: "org.leetio.livecall.history")
    /// Reading the tail is enough to restore the panel, and it keeps startup
    /// flat as the log grows over months.
    private static let tailBytes = 512 * 1024

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        // A log a human might open. ISO dates over epoch doubles.
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    init(directory: URL? = nil) {
        let dir = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Livecall", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        url = dir.appendingPathComponent("history.jsonl")
    }

    var path: String { url.path }

    /// The most recent `limit` records, oldest first. Anything unreadable is
    /// skipped rather than fatal — a line truncated by a crash must not cost
    /// the whole history.
    func load(limit: Int) -> [AnswerRecord] {
        guard let data = tailData() else { return [] }
        let lines = (String(data: data, encoding: .utf8) ?? "")
            .split(separator: "\n", omittingEmptySubsequences: true)
        return lines
            .suffix(limit)
            .compactMap { try? decoder.decode(AnswerRecord.self, from: Data($0.utf8)) }
    }

    func append(_ record: AnswerRecord) {
        guard let line = try? encoder.encode(record) else { return }
        queue.async { [url] in
            var data = line
            data.append(0x0A) // \n
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url, options: .atomic)
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
        }
    }

    func clear() {
        queue.async { [url] in
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// The last `tailBytes` of the file, minus whatever partial line that cut
    /// lands in the middle of.
    private func tailData() -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        guard size > 0 else { return nil }
        let offset = size > UInt64(Self.tailBytes) ? size - UInt64(Self.tailBytes) : 0
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd() else { return nil }
        guard offset > 0, let nl = data.firstIndex(of: 0x0A) else { return data }
        return data[data.index(after: nl)...]
    }
}
