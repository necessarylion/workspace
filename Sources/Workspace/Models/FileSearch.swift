import Foundation

/// One matching line, as the search pane lists it.
struct FileSearchMatch: Identifiable, Hashable {
    let line: Int
    /// The line itself, already trimmed of its indentation — the pane is narrow
    /// and the leading whitespace of a deeply nested line would fill it.
    let text: String
    var id: Int { line }
}

/// Every match inside one file, grouped the way VS Code groups them.
struct FileSearchFileResult: Identifiable, Hashable {
    let url: URL
    /// Folder the file sits in, relative to the repository root, for the dim
    /// subtitle next to the name. Empty at the root.
    let folder: String
    var matches: [FileSearchMatch]
    var id: URL { url }
}

/// A content search over a repository: the query is looked for *inside* files,
/// not in their names.
///
/// ripgrep does the work when it is installed — it is what VS Code searches
/// with, and on a large repository nothing else is close. `git grep` covers the
/// machine that has no `rg`, and plain `grep` covers a folder that is not a
/// repository at all.
enum FileSearcher {
    /// Caps, so even a one-letter query on a huge repository comes back at once.
    /// The pane is a place to find a line, not to read every hit.
    static let maxMatchesPerFile = 50
    static let maxLines = 2000

    /// Drops the remembered answer to "is ripgrep there?". Settings installs it
    /// while the app is running, and the search would otherwise keep falling
    /// back to `git grep` until the next launch.
    static func forgetRipgrep() {
        Task { await RipgrepAvailability.shared.forget() }
    }

    /// ripgrep can be told which byte separates the fields of a match line, and
    /// a control character is the one thing a path cannot contain — so the
    /// output parses exactly, colons in file names and all.
    private static let unitSeparator = "\u{1f}"

    static func search(
        _ query: String,
        in root: URL,
        includingIgnored: Bool
    ) async -> [FileSearchFileResult] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }

        let hasRipgrep = await RipgrepAvailability.shared.value()
        guard !Task.isCancelled else { return [] }

        let output = await Shell.runScript(
            hasRipgrep
                ? ripgrepScript(query, includingIgnored: includingIgnored)
                : fallbackScript(query, includingIgnored: includingIgnored),
            in: root,
            timeout: 30
        )
        guard !Task.isCancelled else { return [] }

        return parse(
            output.stdout,
            separator: hasRipgrep ? unitSeparator : ":",
            root: root
        )
    }

    /// Literal, case-insensitive unless the query itself carries a capital —
    /// both are what the search box does before its regex and case toggles are
    /// turned on. `command` skips any shell function of the same name.
    private static func ripgrepScript(_ query: String, includingIgnored: Bool) -> String {
        var arguments = [
            "command", "rg",
            "--no-heading", "--with-filename", "--line-number",
            "--color=never", "--fixed-strings", "--smart-case",
            "--hidden", "--glob=!.git",
            // A minified bundle is one endless line; it is still a match, but
            // only the part around it is worth carrying back.
            "--max-columns=400", "--max-columns-preview",
            "--max-count=\(maxMatchesPerFile)",
            "--field-match-separator=\(unitSeparator)",
            "--", query
        ]
        if includingIgnored {
            arguments.insert("--no-ignore", at: 2)
        }
        // `head` closing the pipe stops ripgrep where the cap is, rather than
        // letting it walk the rest of the repository for output nobody reads.
        return arguments.map(Shell.quote).joined(separator: " ") + " | head -n \(maxLines)"
    }

    /// `git grep` sees the same files ripgrep would — tracked plus untracked,
    /// minus what `.gitignore` covers. Outside a repository there is no index to
    /// ask, so plain `grep` walks the folder.
    private static func fallbackScript(_ query: String, includingIgnored: Bool) -> String {
        let quoted = Shell.quote(query)
        // `--untracked` alone still leaves out what `.gitignore` covers;
        // dropping the standard excludes is what brings those files back.
        let scope = includingIgnored ? "--untracked --no-exclude-standard" : "--untracked"
        return """
        if git rev-parse --git-dir >/dev/null 2>&1; then \
        git grep -I -n --no-color \(scope) -F -i -e \(quoted) -- .; \
        else grep -rIn -F -i -e \(quoted) .; fi | head -n \(maxLines)
        """
    }

    /// `path<sep>line<sep>text` per line, already grouped by file by every tool
    /// above — so a run of lines sharing a path is one result.
    private static func parse(
        _ output: String,
        separator: String,
        root: URL
    ) -> [FileSearchFileResult] {
        var results: [FileSearchFileResult] = []
        var index: [String: Int] = [:]

        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = line.components(separatedBy: separator)
            guard fields.count >= 3, let number = Int(fields[1]) else { continue }
            let path = fields[0].hasPrefix("./") ? String(fields[0].dropFirst(2)) : fields[0]
            guard !path.isEmpty else { continue }
            let text = fields.dropFirst(2)
                .joined(separator: separator)
                .trimmingCharacters(in: .whitespaces)

            if let existing = index[path] {
                guard results[existing].matches.count < maxMatchesPerFile else { continue }
                results[existing].matches.append(FileSearchMatch(line: number, text: text))
            } else {
                index[path] = results.count
                results.append(FileSearchFileResult(
                    url: root.appendingPathComponent(path),
                    folder: (path as NSString).deletingLastPathComponent,
                    matches: [FileSearchMatch(line: number, text: text)]
                ))
            }
        }
        return results
    }
}

/// Whether `rg` is on the resolved PATH, asked once. The answer decides every
/// keystroke's command, and a shell start per keystroke is exactly the cost this
/// search cannot afford.
private actor RipgrepAvailability {
    static let shared = RipgrepAvailability()

    private var resolution: Task<Bool, Never>?

    func value() async -> Bool {
        if let resolution { return await resolution.value }
        let task = Task { await Shell.isAvailable("rg") }
        resolution = task
        return await task.value
    }

    func forget() { resolution = nil }
}
