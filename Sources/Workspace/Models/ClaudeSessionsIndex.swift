import Foundation

/// One conversation Claude Code has already had about this folder.
struct ClaudePastSession: Identifiable, Sendable, Equatable {
    /// The CLI's session id, which is also its file's name.
    let id: String
    let file: URL
    /// What the conversation is called — see ``ClaudeSessionName``.
    let title: String
    let modified: Date
}

/// What a conversation is called, and where the name came from.
///
/// Claude Code names a conversation itself and writes that name into the
/// transcript, which is the name it also puts on the terminal — so a row can
/// say the same thing the CLI does. Until it has, the first thing that was
/// asked stands in, and ``isFinal`` is how a watcher knows to keep looking.
struct ClaudeSessionName: Sendable, Equatable {
    let text: String
    /// True only for the CLI's own name, which it settles on once and keeps.
    let isFinal: Bool
}

/// The conversations already on disk for a folder.
///
/// Claude Code writes every session to `~/.claude/projects/<folder>/<id>.jsonl`,
/// whatever started it — this window or a shell — so this is one list of both.
/// Reading the files is the only way to get it: the CLI's own `--resume` picker
/// is interactive and has nothing to print.
enum ClaudeSessionsIndex {
    /// Claude Code names a project's folder after its path, with everything
    /// that is not a letter, a digit or a dash turned into a dash —
    /// `/Users/me/.config/app` becomes `-Users-me--config-app`.
    static func directory(for project: URL) -> URL {
        let path = project.standardizedFileURL.path
        let name = String(path.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "-" })
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects/\(name)", isDirectory: true)
    }

    /// Every conversation about this folder, newest first. Off the main actor:
    /// it is a folder listing plus the head of each file.
    static func sessions(for project: URL) async -> [ClaudePastSession] {
        let folder = directory(for: project)
        return await Task.detached(priority: .utility) {
            let manager = FileManager.default
            guard let names = try? manager.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { return [] }

            return names
                .filter { $0.pathExtension == "jsonl" }
                .compactMap { file -> ClaudePastSession? in
                    let values = try? file.resourceValues(forKeys: [.contentModificationDateKey])
                    return ClaudePastSession(
                        id: file.deletingPathExtension().lastPathComponent,
                        file: file,
                        title: name(of: file)?.text ?? "Untitled conversation",
                        modified: values?.contentModificationDate ?? .distantPast
                    )
                }
                .sorted { $0.modified > $1.modified }
        }.value
    }

    /// What one conversation is called, by id — for the ones running right now,
    /// where reading the whole folder the list above walks would be far more
    /// work than the single file this needs. Nil until its first prompt has
    /// landed and the CLI has written the transcript.
    static func name(of id: String, in project: URL) async -> ClaudeSessionName? {
        let file = directory(for: project).appendingPathComponent("\(id).jsonl")
        return await Task.detached(priority: .utility) { name(of: file) }.value
    }

    /// Throws a conversation away: the transcript **and** the folder of tool
    /// output the CLI keeps beside it under the same name.
    ///
    /// To the Trash rather than unlinked, the same as deleting from the Files
    /// tab — a conversation is worth being able to change your mind about, and
    /// recoverable is why neither of them stops to ask first. Returns what went
    /// wrong, when something did.
    static func delete(_ session: ClaudePastSession) async -> String? {
        let sidecar = session.file
            .deletingPathExtension()  // …/<id>.jsonl → …/<id>
        return await Task.detached(priority: .userInitiated) {
            let manager = FileManager.default
            var targets = [session.file]
            if manager.fileExists(atPath: sidecar.path) {
                targets.append(sidecar)
            }
            let result = FileOperations.trash(targets)
            return result.errors.first
        }.value
    }

    /// What a conversation is called, read out of the top of its transcript.
    ///
    /// The CLI's own `ai-title` wins when there is one, so a conversation reads
    /// the same here as it does on the terminal it is running in. Older
    /// transcripts have no such line and the first thing that was asked stands
    /// in — off the `last-prompt` line the CLI writes beside it, or, older
    /// still, out of the first user message itself.
    ///
    /// Read a **line at a time**, not as a fixed head: a pasted screenshot is a
    /// megabyte of base64 on the same line as the prompt beside it, and a head
    /// cut that line in half — which left every conversation that began with an
    /// image untitled. Only the top of the file is worth reading either way, so
    /// the scan gives up after ``scanLines``/``scanBytes``, and stops the moment
    /// it has a name the CLI chose. A stand-in keeps looking a little longer,
    /// because the `ai-title` lands within a few lines of the prompt.
    private static func name(of file: URL) -> ClaudeSessionName? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }

        var reader = LineReader(handle: handle)
        var standIn: String?
        var linesSinceStandIn = 0

        for _ in 0..<scanLines {
            guard reader.bytesRead < scanBytes, let line = reader.next() else { break }
            if standIn != nil {
                linesSinceStandIn += 1
                if linesSinceStandIn > linesPastStandIn { break }
            }
            guard let entry = JSONValue.parse(line) else { continue }

            switch entry["type"]?.stringValue ?? "" {
            case "ai-title":
                if let name = headline(of: entry["aiTitle"]?.stringValue ?? "") {
                    return ClaudeSessionName(text: name, isFinal: true)
                }
            case "last-prompt":
                if standIn == nil {
                    standIn = headline(of: entry["lastPrompt"]?.stringValue ?? "")
                }
            case "user":
                guard standIn == nil,
                      entry["isSidechain"]?.boolValue != true,
                      let content = entry["message"]?["content"] else { continue }
                for prompt in prompts(in: content) {
                    guard let headline = headline(of: prompt) else { continue }
                    standIn = headline
                    break
                }
            default:
                continue
            }
        }
        return standIn.map { ClaudeSessionName(text: $0, isFinal: false) }
    }

    /// How far into a transcript the name is looked for. Generous enough for a
    /// conversation that opens with several pasted images, and no further: the
    /// rest of the file is the conversation itself.
    private static let scanLines = 200
    private static let scanBytes = 8 * 1024 * 1024
    /// How much further to read once the first prompt has been found, hoping
    /// for the name the CLI chose. It writes it within a line or two.
    private static let linesPastStandIn = 20

    /// The text a user entry carries. The CLI writes a typed prompt **either**
    /// way: as a plain string, which is what it does now, or as the blocks a
    /// message is made of, which is what it did and still does whenever the
    /// prompt is more than text — an image, a tool result. Reading only the
    /// blocks left every conversation started by a recent CLI untitled.
    private static func prompts(in content: JSONValue) -> [String] {
        if let text = content.stringValue { return [text] }
        guard let blocks = content.arrayValue else { return [] }
        return blocks.compactMap { block in
            block["type"]?.stringValue == "text" ? block["text"]?.stringValue : nil
        }
    }

    /// A prompt as one line. The CLI puts its own bookkeeping through the same
    /// channel — slash commands, the resumed-session caveat, hook output — and
    /// none of that is what the conversation was about.
    private static func headline(of prompt: String) -> String? {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty,
              !text.hasPrefix("<"),
              !text.hasPrefix("Caveat:"),
              !text.hasPrefix("[Request interrupted") else { return nil }

        let firstLine = text.split(separator: "\n").first.map(String.init) ?? text
        return firstLine.count > 90
            ? String(firstLine.prefix(90)) + "…"
            : firstLine
    }
}

/// A file read one newline-separated line at a time.
///
/// `FileHandle` reads bytes, and a transcript's lines are wildly uneven — a few
/// hundred bytes for most of them, a megabyte for one carrying a pasted image —
/// so this reads in fixed chunks and hands back whole lines out of them,
/// however long they turn out to be. The lines stay `Data`: a line is about to
/// be parsed as JSON, which wants bytes, and turning a megabyte of base64 into
/// a `String` on the way there would be pure waste.
private struct LineReader {
    private let handle: FileHandle
    private var buffer = Data()
    private var atEnd = false
    /// How much of the file has been pulled in, so a caller can stop early.
    private(set) var bytesRead = 0

    private let chunk = 64 * 1024
    private let newline = UInt8(ascii: "\n")

    init(handle: FileHandle) {
        self.handle = handle
    }

    /// The next line, without its newline. Nil at the end of the file.
    mutating func next() -> Data? {
        while true {
            if let end = buffer.firstIndex(of: newline) {
                let line = buffer.subdata(in: buffer.startIndex..<end)
                buffer.removeSubrange(buffer.startIndex...end)
                return line
            }
            guard !atEnd else {
                guard !buffer.isEmpty else { return nil }
                defer { buffer = Data() }
                return buffer
            }
            guard let more = try? handle.read(upToCount: chunk), !more.isEmpty else {
                atEnd = true
                continue
            }
            bytesRead += more.count
            buffer.append(more)
        }
    }
}
