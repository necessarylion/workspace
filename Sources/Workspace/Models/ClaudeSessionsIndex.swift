import Foundation

/// One conversation Claude Code has already had about this folder.
struct ClaudePastSession: Identifiable, Sendable, Equatable {
    /// The CLI's session id, which is also its file's name.
    let id: String
    let file: URL
    /// The first thing that was asked in it — what the row is called.
    let title: String
    let modified: Date
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
                        title: title(of: file) ?? "Untitled conversation",
                        modified: values?.contentModificationDate ?? .distantPast
                    )
                }
                .sorted { $0.modified > $1.modified }
        }.value
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

    /// The first thing the user actually asked. Only the head of the file is
    /// read — a transcript runs to megabytes, and the answer is near the top.
    private static func title(of file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 256 * 1024),
              let text = String(data: head, encoding: .utf8) else { return nil }

        for line in text.split(separator: "\n") {
            guard let entry = JSONValue.parse(String(line)),
                  entry["type"]?.stringValue == "user",
                  entry["isSidechain"]?.boolValue != true,
                  let blocks = entry["message"]?["content"]?.arrayValue else { continue }

            for block in blocks {
                guard block["type"]?.stringValue == "text",
                      let prompt = block["text"]?.stringValue else { continue }
                guard let headline = headline(of: prompt) else { continue }
                return headline
            }
        }
        return nil
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

    /// A transcript's entries, oldest first, for putting a resumed conversation
    /// back on screen. Sidechains — what a subagent said to itself — are left
    /// out, the same as they are while a conversation is live.
    ///
    /// Only the tail of a very long transcript is read: what is wanted is the
    /// conversation you are coming back to, not every tool call of the last
    /// three hours.
    static func transcript(of file: URL, limit: Int = 8 * 1024 * 1024) async -> [JSONValue] {
        await Task.detached(priority: .userInitiated) {
            guard let handle = try? FileHandle(forReadingFrom: file) else { return [] }
            defer { try? handle.close() }

            let size = (try? handle.seekToEnd()) ?? 0
            var data: Data?
            if size > UInt64(limit) {
                try? handle.seek(toOffset: size - UInt64(limit))
                data = try? handle.readToEnd()
                // The cut lands mid-line; that half line is not JSON.
                if let cut = data, let newline = cut.firstIndex(of: 0x0A) {
                    data = cut[cut.index(after: newline)...]
                }
            } else {
                try? handle.seek(toOffset: 0)
                data = try? handle.readToEnd()
            }

            guard let data, let text = String(data: data, encoding: .utf8) else { return [] }
            return text
                .split(separator: "\n")
                .compactMap { JSONValue.parse(String($0)) }
                .filter { $0["isSidechain"]?.boolValue != true }
        }.value
    }
}
