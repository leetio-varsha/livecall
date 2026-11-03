import SwiftUI
import AppKit
import PDFKit

/// Call context: paste a block of text, attach a file (a spec, a proposal,
/// meeting notes), or attach a folder of briefing materials before the call
/// starts.
///
/// The single-line NSAlert this replaces was fine for a one-line topic and
/// useless for anything real.
///
/// Why the size readout matters: context lands in the conversation prefix and
/// is therefore part of EVERY hotkey press for the rest of the call. Prompt
/// caching makes presses after the first cheap, but a 40-page PDF still costs
/// real money and real latency on the first one — so the cost is shown before
/// you commit, and oversized input is truncated with an explicit notice rather
/// than silently sent.
@MainActor
final class ContextWindow: NSObject {
    static let shared = ContextWindow()
    private var window: NSWindow?

    func show(state: AppState) {
        if window == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false)
            w.title = "Call context"
            w.isReleasedWhenClosed = false
            w.center()
            w.contentView = NSHostingView(rootView: ContextView(state: state) { [weak self] in
                self?.window?.close()
            })
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// What a chunk of context will cost per hotkey press.
struct ContextEstimate {
    let chars: Int
    let tokens: Int
    /// First press pays the cache-write premium: 1.25x input on the 5-minute
    /// cache, 2x on the 1-hour one (CACHE_TTL in .env).
    let firstPressUSD: Double
    /// Later presses read the cache (0.1x input).
    let laterPressUSD: Double

    init(chars: Int, tokens: Int, inputRatePer1M: Double, cacheWritePremium: Double) {
        self.chars = chars
        self.tokens = tokens
        let perMillion = Double(tokens) / 1_000_000 * inputRatePer1M
        self.firstPressUSD = perMillion * cacheWritePremium
        self.laterPressUSD = perMillion * 0.1
    }

    static func of(_ text: String, inputRatePer1M: Double, cacheWritePremium: Double) -> ContextEstimate {
        ContextEstimate(chars: text.count, tokens: tokenGuess(text),
                        inputRatePer1M: inputRatePer1M, cacheWritePremium: cacheWritePremium)
    }

    /// Rough token count. Cyrillic runs ~2 chars/token, Latin ~4, so weight by
    /// script instead of using one ratio that's wrong for mixed ru/en text.
    static func tokenGuess(_ text: String) -> Int {
        var ascii = 0, wide = 0
        for scalar in text.unicodeScalars {
            if scalar.isASCII { ascii += 1 } else { wide += 1 }
        }
        return max(0, ascii / 4 + wide / 2)
    }
}

/// One candidate found inside an attached folder.
struct FolderFile: Identifiable {
    var id: String { url.path }
    let url: URL
    /// Path relative to the folder root — what the row shows.
    let name: String
    let modified: Date?
    /// Extracted text; empty when `problem` says why it couldn't be read.
    let text: String
    let chars: Int
    let tokens: Int
    /// Why this file can't be attached (scan PDF, unreadable, oversized).
    let problem: String?
    var selected: Bool
}

/// A folder scanned the way the Attach button sees it.
struct FolderScan {
    let root: URL
    let files: [FolderFile]
    /// The scan stopped early — the folder had more than the caps below.
    let hitCap: Bool

    /// mtime is shown per file AND stamped into the prompt: call packs are
    /// edited up to minutes before the call, and "which version did the model
    /// get" must never be a guess.
    static let mtime: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    static func scan(_ root: URL) -> FolderScan {
        let exts: Set<String> = ["pdf", "txt", "text", "md", "markdown", "rtf"]
        // More rows than this stop being a selection UI; and never walk all of
        // ~/Downloads just because it was picked by mistake.
        let fileCap = 60
        let entryCap = 5000
        // A file this big could never fit CONTEXT_MAX_CHARS — reading it would
        // only stall the window.
        let byteCap = 2 << 20

        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        var files: [FolderFile] = []
        var hitCap = false
        var seen = 0
        let walker = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            // Hidden dirs (.idea, .git) are IDE noise, never call material.
            options: [.skipsHiddenFiles, .skipsPackageDescendants])
        while let url = walker?.nextObject() as? URL {
            seen += 1
            if seen > entryCap || files.count >= fileCap {
                hitCap = true
                break
            }
            guard exts.contains(url.pathExtension.lowercased()),
                  let rv = try? url.resourceValues(forKeys: keys),
                  rv.isRegularFile == true else { continue }
            let name = relativeName(of: url, in: root)
            let modified = rv.contentModificationDate
            let unreadable = { (why: String) in
                files.append(FolderFile(
                    url: url, name: name, modified: modified,
                    text: "", chars: 0, tokens: 0, problem: why, selected: false))
            }
            if let size = rv.fileSize, size > byteCap {
                unreadable("too big (\(size / 1024 / 1024) MB) — would never fit the context cap")
                continue
            }
            do {
                let text = try ContextView.extractText(from: url)
                if text.trimmingCharacters(in: .whitespacesAndNewlines).count < 20 {
                    unreadable(url.pathExtension.lowercased() == "pdf"
                               ? "no text layer — probably a scan" : "empty file")
                    continue
                }
                files.append(FolderFile(
                    url: url, name: name, modified: modified,
                    text: text, chars: text.count,
                    tokens: ContextEstimate.tokenGuess(text),
                    problem: nil,
                    // The one filename convention briefing packs use: the
                    // file written FOR the copilot is called BRIEFING.md. It
                    // starts checked; everything else is a choice.
                    selected: name.lowercased() == "briefing.md"))
            } catch {
                unreadable("couldn't read: \(error.localizedDescription)")
            }
        }
        return FolderScan(
            root: root,
            files: files.sorted { $0.name.localizedCompare($1.name) == .orderedAscending },
            hitCap: hitCap)
    }

    private static func relativeName(of url: URL, in root: URL) -> String {
        let rootPath = root.standardizedFileURL.path + "/"
        let p = url.standardizedFileURL.path
        return p.hasPrefix(rootPath) ? String(p.dropFirst(rootPath.count)) : url.lastPathComponent
    }
}

struct ContextView: View {
    @ObservedObject var state: AppState
    let onDone: () -> Void

    @State private var text = ""
    @State private var attachedFrom: String?
    @State private var problem: String?
    @State private var truncatedFrom: Int?
    @State private var folderURL: URL?
    @State private var folderFiles: [FolderFile] = []
    @State private var folderHitCap = false
    @State private var projectName = ""
    @State private var savedProject: String?

    init(state: AppState, initialScan: FolderScan? = nil, onDone: @escaping () -> Void) {
        self.state = state
        self.onDone = onDone
        // Seeded state, not onAppear: the selftest renders this view OFFSCREEN
        // (no window, no appear pass), and the menu path passes nothing.
        if let scan = initialScan {
            _folderURL = State(initialValue: scan.root)
            _folderFiles = State(initialValue: scan.files)
            _folderHitCap = State(initialValue: scan.hitCap)
            _projectName = State(initialValue: Self.defaultProjectName(scan.root))
        }
    }

    /// Above this, context stops being worth what it costs on every press.
    /// Override with CONTEXT_MAX_CHARS in core/.env.
    private var maxChars: Int { state.contextMaxChars }

    private var selectedFiles: [FolderFile] {
        folderFiles.filter { $0.selected && $0.problem == nil }
    }

    /// Typed text plus every checked file. Sums of the cached per-file counts,
    /// not a re-walk of a 100KB concatenation on every keystroke; the ~45-char
    /// file headers are noise next to the files themselves.
    private var estimate: ContextEstimate {
        let typed = ContextEstimate.of(text, inputRatePer1M: state.inputRatePer1M, cacheWritePremium: state.cacheWritePremium)
        return ContextEstimate(
            chars: typed.chars + selectedFiles.reduce(0) { $0 + $1.chars },
            tokens: typed.tokens + selectedFiles.reduce(0) { $0 + $1.tokens },
            inputRatePer1M: state.inputRatePer1M, cacheWritePremium: state.cacheWritePremium)
    }

    /// A folder over the cap is not truncated like a single file — cutting an
    /// arbitrary tail out of N files is a silent lie about what was attached.
    /// The user unchecks files instead, and the label below says why.
    private var overCap: Bool { estimate.chars > maxChars }

    private var canAdd: Bool {
        let hasContent = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !selectedFiles.isEmpty
        return hasContent && !overCap
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Anything the assistant should know before the questions start — who you're talking to, the project, your role. Or attach briefing notes (a spec, a proposal, meeting notes) — or a whole folder of call materials.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextEditor(text: $text)
                .font(.system(size: 12, design: .monospaced))
                .frame(minHeight: folderFiles.isEmpty ? 240 : 120)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(.separator))

            if let attachedFrom {
                Label("from \(attachedFrom)", systemImage: "paperclip")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let truncatedFrom {
                Label(
                    "Trimmed to \(maxChars.formatted()) characters (file had \(truncatedFrom.formatted())). The rest was dropped — keep the part that matters most at the top.",
                    systemImage: "scissors")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !folderFiles.isEmpty { folderSection }
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // The honest cost of what's about to be attached, before committing.
            if estimate.chars > 0 {
                let e = estimate
                Text("\(e.chars.formatted()) characters · ≈\(e.tokens.formatted()) tokens · adds ≈\(money(e.firstPressUSD)) to the first press, ≈\(money(e.laterPressUSD)) to each one after (cached)")
                    .font(.caption2)
                    .foregroundStyle(e.tokens > 15_000 ? .orange : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if overCap {
                Label(
                    "Over the \(maxChars.formatted())-character cap — deselect some files or trim the text.",
                    systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Attach file or folder…") { pickFile() }
                Button("Clear") {
                    text = ""; attachedFrom = nil; problem = nil; truncatedFrom = nil
                    folderURL = nil; folderFiles = []; folderHitCap = false
                }
                .disabled(text.isEmpty && folderFiles.isEmpty)
                Spacer()
                Button("Cancel") { onDone() }
                    .keyboardShortcut(.cancelAction)
                Button("Add") {
                    state.addContext(composedContext(), source: sourceLabel)
                    onDone()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canAdd)
            }
        }
        .padding(18)
        .frame(minWidth: 460, minHeight: 440)
    }

    private var folderSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label(folderURL?.lastPathComponent ?? "folder", systemImage: "folder")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("all") { setSelection(true) }
                    .buttonStyle(.borderless).font(.caption)
                Button("none") { setSelection(false) }
                    .buttonStyle(.borderless).font(.caption)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach($folderFiles) { $file in
                        folderRow($file)
                    }
                }
                .padding(6)
            }
            .frame(maxHeight: 170)
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(.separator))
            if folderHitCap {
                Label("The folder has more files than that — scan stopped at \(folderFiles.count). Attach a smaller folder if something is missing.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption2).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Persist the CHECKED files as a named project: the menu can then
            // arm it, and the files are re-read fresh on every call start —
            // no re-picking the same folder before each call about it.
            if !selectedFiles.isEmpty {
                HStack(spacing: 6) {
                    TextField("project name", text: $projectName)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                        .frame(width: 180)
                    Button("Save as project") {
                        let name = projectName.trimmingCharacters(in: .whitespaces)
                        // Readable-but-unchecked files become the shelf: not
                        // briefed, but on call the scout can pull one the
                        // moment its topic comes up.
                        let shelf = folderFiles
                            .filter { $0.problem == nil && !$0.selected }
                            .map(\.url.path)
                        state.saveProject(
                            name: name, files: selectedFiles.map(\.url.path), shelf: shelf)
                        savedProject = name
                    }
                    .disabled(projectName.trimmingCharacters(in: .whitespaces).isEmpty)
                    if let savedProject {
                        Label("“\(savedProject)” saved — arm it via the menu", systemImage: "checkmark.circle")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }
        }
    }

    @ViewBuilder private func folderRow(_ file: Binding<FolderFile>) -> some View {
        let f = file.wrappedValue
        HStack(spacing: 6) {
            if let why = f.problem {
                Image(systemName: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
                Text(f.name).font(.system(size: 12))
                Text(why).font(.caption2).foregroundStyle(.orange)
                    .lineLimit(1)
                Spacer()
            } else {
                Toggle(isOn: file.selected) {
                    Text(f.name).font(.system(size: 12))
                }
                .toggleStyle(.checkbox)
                Spacer()
                Text("≈\(f.tokens.formatted()) tok\(mtimeSuffix(f.modified))")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func mtimeSuffix(_ d: Date?) -> String {
        guard let d else { return "" }
        return " · " + FolderScan.mtime.string(from: d)
    }

    private func setSelection(_ on: Bool) {
        for i in folderFiles.indices where folderFiles[i].problem == nil {
            folderFiles[i].selected = on
        }
    }

    /// Typed note first, then each checked file under a header naming it and
    /// its mtime — so the model (and the user reading the transcript later)
    /// knows exactly which version of which file it was given.
    private func composedContext() -> String {
        var parts: [String] = []
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty { parts.append(typed) }
        for f in selectedFiles {
            let stamp = f.modified.map { " (modified \(FolderScan.mtime.string(from: $0)))" } ?? ""
            parts.append("=== FILE: \(f.name)\(stamp) ===\n"
                + f.text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return parts.joined(separator: "\n\n")
    }

    private var sourceLabel: String? {
        guard !selectedFiles.isEmpty else { return attachedFrom }
        let folder = folderURL?.lastPathComponent ?? "folder"
        let base = "\(folder) (\(selectedFiles.count) file\(selectedFiles.count == 1 ? "" : "s"))"
        return attachedFrom.map { "\(base) + \($0)" } ?? base
    }

    private func money(_ usd: Double) -> String {
        usd < 0.01 ? String(format: "$%.4f", usd) : String(format: "$%.3f", usd)
    }

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.allowedContentTypes = [.pdf, .plainText, .text, .rtf, .folder]
        panel.message = "PDF or a text file (txt, md, rtf), or a folder of call materials"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            loadFolder(url)
            return
        }

        problem = nil
        truncatedFrom = nil
        do {
            var extracted = try Self.extractText(from: url)
            if extracted.trimmingCharacters(in: .whitespacesAndNewlines).count < 20 {
                problem = url.pathExtension.lowercased() == "pdf"
                    ? "No text found in that PDF — it's probably a scan. Livecall can't read images; export a text PDF or paste the text."
                    : "That file appears to be empty."
                return
            }
            if extracted.count > maxChars {
                truncatedFrom = extracted.count
                extracted = String(extracted.prefix(maxChars))
            }
            // Append rather than replace, so a file and a typed note can coexist.
            text = text.isEmpty ? extracted : text + "\n\n" + extracted
            attachedFrom = url.lastPathComponent
        } catch {
            problem = "Couldn't read that file: \(error.localizedDescription)"
        }
    }

    private func loadFolder(_ url: URL) {
        problem = nil
        truncatedFrom = nil
        let scan = FolderScan.scan(url)
        if scan.files.isEmpty {
            problem = "No readable files in that folder (pdf / txt / md / rtf)."
            return
        }
        folderURL = url
        folderFiles = scan.files
        folderHitCap = scan.hitCap
        savedProject = nil
        projectName = Self.defaultProjectName(url)
    }

    /// Folder name minus a trailing date: "sumatrix-demo-2026-08-25" packs
    /// are per-call, but the PROJECT they belong to is just "sumatrix-demo".
    static func defaultProjectName(_ url: URL) -> String {
        url.lastPathComponent.replacingOccurrences(
            of: #"-\d{4}-\d{2}-\d{2}$"#, with: "", options: .regularExpression)
    }

    /// PDF via PDFKit (no dependency, handles Cyrillic); everything else as text.
    static func extractText(from url: URL) throws -> String {
        if url.pathExtension.lowercased() == "pdf" {
            guard let doc = PDFDocument(url: url) else {
                throw NSError(domain: "livecall", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "not a readable PDF",
                ])
            }
            return doc.string ?? ""
        }
        if url.pathExtension.lowercased() == "rtf",
           let attributed = try? NSAttributedString(
               url: url, options: [.documentType: NSAttributedString.DocumentType.rtf],
               documentAttributes: nil) {
            return attributed.string
        }
        return try String(contentsOf: url, encoding: .utf8)
    }
}
