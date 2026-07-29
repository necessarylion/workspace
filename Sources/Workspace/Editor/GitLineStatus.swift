import Foundation

/// What git says happened to one line of the file currently on screen.
enum GitLineChange: Sendable, Equatable {
    case added
    case modified
    /// Lines were deleted at the gap *above* this one. A deletion has no line of
    /// its own to sit beside — it is a place where lines used to be — so it is
    /// recorded against the line that closed over it and drawn as a wedge on that
    /// line's top edge.
    case deleted
}

/// Every line of one file that differs from the commit behind it, keyed by
/// **zero-based** line index, which is what the editor counts in.
///
/// Deliberately a value: it is computed off the main thread and handed to the
/// gutter whole, so there is never a half-updated map to draw from.
struct GitLineStatus: Sendable, Equatable {
    struct Marker: Sendable, Equatable {
        let line: Int
        let change: GitLineChange
    }

    /// Sorted by line, because the gutter walks the lines it can see and wants to
    /// find the first marker at or after one of them without touching the rest.
    /// A file with a thousand changed lines shows twenty of them at a time.
    private(set) var markers: [Marker] = []

    static let none = GitLineStatus()

    var isEmpty: Bool { markers.isEmpty }

    /// Where in ``markers`` to start, for a gutter asked to draw from part-way
    /// down the file.
    func firstIndex(atOrAfter line: Int) -> Int {
        var low = 0
        var high = markers.count
        while low < high {
            let mid = (low + high) / 2
            if markers[mid].line < line { low = mid + 1 } else { high = mid }
        }
        return low
    }

    init(byLine: [Int: GitLineChange] = [:]) {
        markers = byLine
            .map { Marker(line: $0.key, change: $0.value) }
            .sorted { $0.line < $1.line }
    }
}

/// Reads the working tree's diff for one file and reduces it to the per-line
/// verdict the gutter draws.
///
/// **Against the commit, not against what is being typed.** The markers are
/// recomputed when the file is opened, when something outside the editor rewrites
/// it, and when it is saved — never per keystroke. So while there are unsaved
/// edits the stripes describe the file as it was last written, and a line the user
/// is in the middle of adding gets no marker until they save. Running `git diff`
/// on every keystroke would mean a process per character; diffing the in-memory
/// text against the blob instead would mean a second diff implementation, and one
/// that disagrees with the diff viewer over what counts as a change. Neither is
/// worth what it buys, and a stripe that appears on save is the behaviour every
/// editor with this feature has.
enum GitLineStatusLoader {
    /// - Parameters:
    ///   - file: The open file.
    ///   - projectRoot: Any directory inside the repository — the added project's
    ///     folder will do, since git is asked for the real top level from there.
    static func load(file: URL, in projectRoot: URL) async -> GitLineStatus {
        let root = await GitStatus.root(of: projectRoot)
        guard let path = relativePath(of: file, under: root) else { return .none }

        // Asked first because it is the cheap question and its answer is usually
        // "nothing": an unchanged file is the common case, and one `git status`
        // on a single path is a great deal less work than a diff. It also tells
        // the two interesting cases apart — an untracked file has no diff against
        // the commit at all, and has to be asked for with `--no-index` instead,
        // or the whole of a brand new file would be marked as unchanged.
        let status = await Shell.run(
            ["git", "status", "--porcelain", "--", path],
            in: root,
            timeout: 15
        )
        let entry = status.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard status.isSuccess, !entry.isEmpty else { return .none }
        let isUntracked = entry.hasPrefix("??")

        let text = await GitStatus.diff(paths: [path], in: root, isUntracked: isUntracked)
        guard !text.isEmpty else { return .none }

        let diff = await DiffParser.parseInBackground(text)
        return reduce(diff)
    }

    /// The path git wants: relative to the top level, with no leading slash.
    /// Nil when the file is not under the repository at all, which is the answer
    /// for a file opened from somewhere else entirely.
    private static func relativePath(of file: URL, under root: URL) -> String? {
        let filePath = file.standardizedFileURL.resolvingSymlinksInPath().path
        var rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        if !rootPath.hasSuffix("/") { rootPath += "/" }
        guard filePath.hasPrefix(rootPath) else { return nil }
        return String(filePath.dropFirst(rootPath.count))
    }

    /// One parsed diff → one marker per changed line.
    ///
    /// The parser has already done the hard half: it pairs a run of removed lines
    /// against the run of added lines that replaced it, so a rewritten line
    /// arrives as a single `.changed` row rather than as a deletion and an
    /// addition that have to be recognised as the same edit here.
    ///
    /// What is left is where a deletion goes. It has no line in the new file, so
    /// the count of lines the hunk has produced so far is carried along and the
    /// deletion is pinned to the gap in front of it — which is the line the user
    /// now sees there, and the one whose top edge gets the wedge.
    private static func reduce(_ diff: Diff) -> GitLineStatus {
        guard let file = diff.files.first else { return .none }
        var byLine: [Int: GitLineChange] = [:]

        for hunk in file.hunks {
            var newCursor = newStart(of: hunk.header)
            for row in hunk.rows {
                switch row.kind {
                case .context:
                    newCursor = (row.newNumber ?? newCursor) + 1
                case .added, .changed:
                    if let number = row.newNumber {
                        byLine[number - 1] = row.kind == .added ? .added : .modified
                        newCursor = number + 1
                    }
                case .removed:
                    // Never over an addition or a rewrite: a line that is both
                    // the replacement for something and the lid on a deletion is
                    // more usefully drawn as the change it is.
                    let index = max(0, newCursor - 1)
                    if byLine[index] == nil { byLine[index] = .deleted }
                }
            }
        }

        return GitLineStatus(byLine: byLine)
    }

    /// The new-file line a hunk starts at, from its `@@ -12,7 +15,9 @@` header.
    ///
    /// The last `+` field rather than the first, so a combined diff — `@@@` with a
    /// field per parent — still yields the side that is the file on screen.
    private static func newStart(of header: String) -> Int {
        let fields = header.split(separator: " ")
        guard let field = fields.last(where: { $0.hasPrefix("+") }) else { return 1 }
        let digits = field.dropFirst().prefix { $0.isNumber }
        return Int(digits) ?? 1
    }
}
