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

    var isEmpty: Bool { files.allSatisfy { $0.hunks.isEmpty } }

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

            if line.hasPrefix("diff --git ") {
                flushFile()
                let paths = parseGitHeaderPaths(line)
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

            if line.hasPrefix("new file mode") {
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
            } else if line.hasPrefix("@@") {
                flushHunk()
                let numbers = parseHunkHeader(line)
                oldLine = numbers.old
                newLine = numbers.new
                currentHunk = DiffHunk(header: line, rows: [])
            } else if currentHunk != nil {
                if line.hasPrefix("-") {
                    removedBuffer.append((oldLine, String(line.dropFirst())))
                    oldLine += 1
                } else if line.hasPrefix("+") {
                    addedBuffer.append((newLine, String(line.dropFirst())))
                    newLine += 1
                } else if line.hasPrefix("\\") {
                    continue // "\ No newline at end of file"
                } else {
                    flushPairs()
                    let content = line.hasPrefix(" ") ? String(line.dropFirst()) : line
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

    private static func parseGitHeaderPaths(_ line: String) -> (old: String, new: String) {
        // diff --git a/old b/new
        let rest = String(line.dropFirst("diff --git ".count))
        guard let range = rest.range(of: " b/") else {
            return (rest, rest)
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
