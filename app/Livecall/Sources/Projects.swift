import Foundation

/// A named, saved list of context files — the materials for calls about one
/// project. Stored as PATHS, not content: packs are edited up to minutes
/// before the call, so the content is read fresh from disk every time the
/// project is activated — including automatically on every call start.
struct Project: Codable, Identifiable, Equatable {
    var name: String
    /// Absolute paths, in the order they were picked in the context window.
    var files: [String]
    /// The SHELF: readable files [Me] left unchecked when saving. Not part of
    /// the briefing — kept so the mid-call scout can pull one the moment its
    /// topic actually comes up, instead of being discarded at save time.
    var shelf: [String]
    var id: String { name }

    init(name: String, files: [String], shelf: [String] = []) {
        self.name = name
        self.files = files
        self.shelf = shelf
    }

    private enum CodingKeys: String, CodingKey { case name, files, shelf }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        files = try c.decode([String].self, forKey: .files)
        // projects.json files written before the shelf existed have no such
        // key — they must keep decoding, or every saved project silently
        // vanishes on the first launch after this update.
        shelf = try c.decodeIfPresent([String].self, forKey: .shelf) ?? []
    }
}

/// What activating a project produced.
struct ProjectContext {
    let text: String
    let fileCount: Int
    /// Files that are missing or unreadable — surfaced, never skipped
    /// silently: a vanished BRIEFING.md is the difference between a briefed
    /// copilot and a blind one that still LOOKS briefed.
    let problems: [String]
}

/// Persistence for projects, next to the answer history. The active project
/// is persisted too: an app restart minutes before the call must not
/// silently drop the briefing.
final class ProjectStore {
    private let url: URL
    private(set) var projects: [Project] = []
    private(set) var activeName: String?

    private struct StoreFile: Codable {
        var active: String?
        var projects: [Project]
    }

    init(url: URL? = nil) {
        self.url = url ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Livecall/projects.json")
        load()
    }

    func setActive(_ name: String?) {
        activeName = name
        persist()
    }

    /// Insert or replace by name — saving the same project again is an update.
    func upsert(_ project: Project) {
        if let i = projects.firstIndex(where: { $0.name == project.name }) {
            projects[i] = project
        } else {
            projects.append(project)
        }
        persist()
    }

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(StoreFile.self, from: data) else { return }
        projects = file.projects
        activeName = file.active
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(StoreFile(active: activeName, projects: projects)) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// Read the project's files fresh and assemble the context block — the
    /// same `=== FILE: … ===` headers the folder attach produces, so the model
    /// sees one consistent format either way.
    static func buildContext(_ project: Project) -> ProjectContext {
        var parts: [String] = []
        var problems: [String] = []
        for path in project.files {
            let url = URL(fileURLWithPath: path)
            let name = url.lastPathComponent
            guard FileManager.default.fileExists(atPath: path) else {
                problems.append("\(name) is missing")
                continue
            }
            do {
                let text = try ContextView.extractText(from: url)
                if text.trimmingCharacters(in: .whitespacesAndNewlines).count < 20 {
                    problems.append("\(name) is empty")
                    continue
                }
                let modified = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date
                let stamp = modified.map { " (modified \(FolderScan.mtime.string(from: $0)))" } ?? ""
                parts.append("=== FILE: \(name)\(stamp) ===\n"
                    + text.trimmingCharacters(in: .whitespacesAndNewlines))
            } catch {
                problems.append("\(name) is unreadable")
            }
        }
        return ProjectContext(
            text: parts.joined(separator: "\n\n"),
            fileCount: parts.count,
            problems: problems)
    }
}
