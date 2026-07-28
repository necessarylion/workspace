import Foundation

/// A parsed unified diff, arranged for side-by-side display.
struct Diff: Sendable, Hashable {
    var files: [DiffFile]
    /// Totals, counted once while parsing. They used to walk every row of
    /// every file, and the diff bar asks for them on every redraw.
    var addedLines = 0
    var removedLines = 0

    /// Identity of one parse.
    ///
    /// A `Diff` is a deep tree of strings, and SwiftUI compares a view's stored
    /// properties to decide whether to re-run its body — for a large pull
    /// request that meant comparing every line of every file. Every diff the
    /// app shows comes straight out of `DiffParser`, so comparing the token is
    /// both cheaper and just as accurate. (`DiffHighlighter` deliberately keeps
    /// the token: its input is never shown on its own.)
    let revision = UUID()

    /// A binary file has no hunks and never will, but it is not nothing — the
    /// diff view has a placeholder that says so. Counting it as empty put the
    /// viewer's "no textual changes" error up instead, and that placeholder
    /// could never be reached for a one-file diff.
    var isEmpty: Bool { files.allSatisfy { $0.hunks.isEmpty && !$0.isBinary } }

    /// Past this many files a diff is never built whole: it is read one file at
    /// a time, and each file is syntax-coloured as it is opened. Colouring a
    /// hundred files up front runs tree-sitter over every hunk of every one of
    /// them on the main actor, and laying them all out is a scroll nobody can
    /// find anything in anyway.
    static let fileByFileThreshold = 20

    /// Whether this diff is too big to show whole — see ``fileByFileThreshold``.
    var isFileByFile: Bool { files.count > Self.fileByFileThreshold }

    static func == (lhs: Diff, rhs: Diff) -> Bool { lhs.revision == rhs.revision }
    func hash(into hasher: inout Hasher) { hasher.combine(revision) }
}

struct DiffFile: Sendable, Hashable, Identifiable {
    enum Change: String, Sendable {
        case modified, added, deleted, renamed
    }

    var oldPath: String
    var newPath: String
    var change: Change
    var hunks: [DiffHunk]
    var isBinary: Bool
    /// Counted while parsing, for the same reason as `Diff`'s totals.
    var addedLines = 0
    var removedLines = 0

    var id: String { "\(oldPath)→\(newPath)" }
    var displayPath: String { change == .renamed ? "\(oldPath) → \(newPath)" : newPath }
}

struct DiffHunk: Sendable, Hashable, Identifiable {
    var header: String
    var rows: [DiffRow]
    var id: String { header + "-\(rows.count)" }
}

/// One visual row. In split view the left cell shows `old*`, the right `new*`.
struct DiffRow: Sendable, Hashable, Identifiable {
    enum Kind: String, Sendable {
        case context, added, removed, changed
    }

    /// Position in the diff, handed out while parsing. It used to be built from
    /// the row's own text, which meant allocating a string as long as the line
    /// every time a list of rows was diffed.
    var id: Int
    var kind: Kind
    var oldNumber: Int?
    var oldText: String?
    var newNumber: Int?
    var newText: String?

    /// The parts of a `changed` row that actually differ, as character offsets
    /// into `oldText` / `newText`. Empty for every other kind of row, and for a
    /// pair too dissimilar for the distinction to mean anything.
    var oldWordRanges: [Range<Int>] = []
    var newWordRanges: [Range<Int>] = []

    // Syntax-coloured versions, filled in by DiffHighlighter after parsing.
    var oldHighlighted: AttributedString?
    var newHighlighted: AttributedString?
}

enum DiffParser {
    /// The same parse, off the main thread.
    ///
    /// `parse` is pure and its result is `Sendable`, but it is not cheap: the
    /// word-level pass runs an LCS over the tokens of every changed line, and a
    /// pull request of a few thousand lines stalls the window for as long as it
    /// takes. Every caller loads its patch with `await` already, so the wait
    /// costs nothing extra and the rest of the app keeps drawing.
    static func parseInBackground(_ text: String) async -> Diff {
        await Task.detached(priority: .userInitiated) { parse(text) }.value
    }

    /// Parses `git diff` / `gh pr diff` output.
    static func parse(_ text: String) -> Diff {
        var files: [DiffFile] = []

        var currentFile: DiffFile?
        var currentHunk: DiffHunk?
        // Buffered -/+ block, paired up when the run ends.
        var removedBuffer: [(Int, String)] = []
        var addedBuffer: [(Int, String)] = []
        var oldLine = 0
        var newLine = 0
        var nextRowID = 0
        /// How many characters of a hunk line are the +/- markers. One for an
        /// ordinary diff, one per parent for a combined (`--cc`) one.
        var markerColumns = 1

        func rowID() -> Int {
            defer { nextRowID += 1 }
            return nextRowID
        }

        func flushPairs() {
            guard !removedBuffer.isEmpty || !addedBuffer.isEmpty else { return }
            let count = max(removedBuffer.count, addedBuffer.count)
            for index in 0..<count {
                let removed = index < removedBuffer.count ? removedBuffer[index] : nil
                let added = index < addedBuffer.count ? addedBuffer[index] : nil
                let kind: DiffRow.Kind = {
                    if removed != nil && added != nil { return .changed }
                    return removed != nil ? .removed : .added
                }()
                // Only a paired line has a counterpart to be compared against.
                let words: (old: [Range<Int>], new: [Range<Int>]) = kind == .changed
                    ? InlineDiff.ranges(old: removed?.1 ?? "", new: added?.1 ?? "")
                    : ([], [])
                currentHunk?.rows.append(
                    DiffRow(
                        id: rowID(),
                        kind: kind,
                        oldNumber: removed?.0,
                        oldText: removed?.1,
                        newNumber: added?.0,
                        newText: added?.1,
                        oldWordRanges: words.old,
                        newWordRanges: words.new
                    )
                )
            }
            removedBuffer.removeAll()
            addedBuffer.removeAll()
        }

        func flushHunk() {
            flushPairs()
            if let hunk = currentHunk, !hunk.rows.isEmpty {
                currentFile?.hunks.append(hunk)
            }
            currentHunk = nil
        }

        func flushFile() {
            flushHunk()
            if var file = currentFile {
                for hunk in file.hunks {
                    for row in hunk.rows {
                        switch row.kind {
                        case .added: file.addedLines += 1
                        case .removed: file.removedLines += 1
                        case .context, .changed: break
                        }
                    }
                }
                files.append(file)
            }
            currentFile = nil
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            // Normalise CRLF endings and expand tabs: the diff view lays rows
            // out at a fixed width computed from character counts, and a tab
            // is one character but four columns wide.
            var line = String(rawLine)
            if line.hasSuffix("\r") { line = String(line.dropLast()) }
            if line.contains("\t") {
                line = line.replacingOccurrences(of: "\t", with: "    ")
            }

            // A merge commit, and a plain `git diff` over an unmerged path,
            // are shown as a *combined* diff instead: a `--cc` header and a
            // marker column per parent. Without the header every line of one
            // was skipped and the file arrived with nothing in it. (The
            // working-tree diff asks against `HEAD`, which git answers with an
            // ordinary two-way diff even mid-conflict, so this is for the
            // diffs that come from elsewhere.)
            if line.hasPrefix("diff --git ") || line.hasPrefix("diff --cc ")
                || line.hasPrefix("diff --combined ") {
                flushFile()
                let paths = parseHeaderPaths(line)
                markerColumns = 1
                currentFile = DiffFile(
                    oldPath: paths.old,
                    newPath: paths.new,
                    change: .modified,
                    hunks: [],
                    isBinary: false
                )
                continue
            }

            guard currentFile != nil else { continue }

            // A hunk header first, then the hunk's own lines. The file headers
            // below are only headers *outside* a hunk: a removed line reading
            // `-- and so on` arrives as `--- and so on`, and testing for that
            // prefix here used to eat the row and rename the file to it.
            if line.hasPrefix("@@") {
                flushHunk()
                let numbers = parseHunkHeader(line)
                oldLine = numbers.old
                newLine = numbers.new
                // One marker column per parent: `@@@` heads a two-parent diff
                // whose rows carry two of them.
                markerColumns = max(1, line.prefix(while: { $0 == "@" }).count - 1)
                currentHunk = DiffHunk(header: line, rows: [])
            } else if currentHunk != nil {
                if line.hasPrefix("\\") {
                    continue // "\ No newline at end of file"
                }
                let markers = String(line.prefix(markerColumns))
                let content = String(line.dropFirst(markerColumns))
                if markers.contains("-") {
                    removedBuffer.append((oldLine, content))
                    oldLine += 1
                } else if markers.contains("+") {
                    addedBuffer.append((newLine, content))
                    newLine += 1
                } else {
                    flushPairs()
                    currentHunk?.rows.append(
                        DiffRow(
                            id: rowID(),
                            kind: .context,
                            oldNumber: oldLine,
                            oldText: content,
                            newNumber: newLine,
                            newText: content
                        )
                    )
                    oldLine += 1
                    newLine += 1
                }
            } else if line.hasPrefix("new file mode") {
                currentFile?.change = .added
            } else if line.hasPrefix("deleted file mode") {
                currentFile?.change = .deleted
            } else if line.hasPrefix("rename from ") {
                currentFile?.change = .renamed
                currentFile?.oldPath = String(line.dropFirst("rename from ".count))
            } else if line.hasPrefix("rename to ") {
                currentFile?.change = .renamed
                currentFile?.newPath = String(line.dropFirst("rename to ".count))
            } else if line.hasPrefix("Binary files ") || line.hasPrefix("GIT binary patch") {
                currentFile?.isBinary = true
            } else if line.hasPrefix("--- ") {
                let path = String(line.dropFirst(4))
                if path != "/dev/null" {
                    currentFile?.oldPath = strippingPrefix(path)
                }
            } else if line.hasPrefix("+++ ") {
                let path = String(line.dropFirst(4))
                if path != "/dev/null" {
                    currentFile?.newPath = strippingPrefix(path)
                }
            }
        }

        flushFile()
        return Diff(
            files: files,
            addedLines: files.reduce(0) { $0 + $1.addedLines },
            removedLines: files.reduce(0) { $0 + $1.removedLines }
        )
    }

    private static func strippingPrefix(_ path: String) -> String {
        if path.hasPrefix("a/") || path.hasPrefix("b/") {
            return String(path.dropFirst(2))
        }
        return path
    }

    /// The paths out of a `diff --git a/old b/new` line — or out of a
    /// `diff --cc file`, which names the one path it is about and no other.
    ///
    /// Both forms are rewritten by the `--- ` and `+++ ` lines that follow
    /// wherever those exist, so the naive split below only has to hold for a
    /// rename, a mode change or a binary, which have neither.
    private static func parseHeaderPaths(_ line: String) -> (old: String, new: String) {
        guard let space = line.dropFirst("diff ".count).firstIndex(of: " ") else {
            return ("", "")
        }
        let rest = String(line[line.index(after: space)...])
        guard let range = rest.range(of: " b/") else {
            // `diff --cc file`: one path, standing for both sides.
            let path = strippingPrefix(rest)
            return (path, path)
        }
        let old = strippingPrefix(String(rest[rest.startIndex..<range.lowerBound]))
        let new = String(rest[range.upperBound...])
        return (old, new)
    }

    private static func parseHunkHeader(_ line: String) -> (old: Int, new: Int) {
        // @@ -12,7 +12,9 @@ optional context
        var old = 1
        var new = 1
        let parts = line.split(separator: " ")
        for part in parts {
            if part.hasPrefix("-") {
                old = Int(part.dropFirst().split(separator: ",").first ?? "1") ?? 1
            } else if part.hasPrefix("+") {
                new = Int(part.dropFirst().split(separator: ",").first ?? "1") ?? 1
            }
        }
        return (old, new)
    }
}
