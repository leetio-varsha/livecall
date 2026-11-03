import Foundation

/// Minimal reader for `core/.env`, so the app and the core agree on the hotkeys
/// and the call-detect exclusions without a second config file. Values are read
/// as written — no shell expansion, no export, no multi-line values.
enum EnvFile {
    static func load(_ path: String) -> [String: String] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [:] }
        var out: [String: String] = [:]
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[line.startIndex..<eq]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if value.count >= 2, (value.hasPrefix("\"") && value.hasSuffix("\""))
                || (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }
            if !key.isEmpty { out[key] = value }
        }
        return out
    }
}
