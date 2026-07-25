import Foundation

/// A parsed unified diff, arranged for side-by-side display.
struct Diff: Sendable, Hashable {
    var files: [DiffFile]

    var isEmpty: Bool { files.allSatisfy { $0.hunks.isEmpty } }
    var addedLines: Int { files.reduce(0) { $0 + $1.addedLines } }
    var removedLines: Int { files.reduce(0) { $0 + $1.removedLines } }
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

    var id: String { "\(oldPath)→\(newPath)" }
    var displayPath: String { change == .renamed ? "\(oldPath) → \(newPath)" : newPath }

    var addedLines: Int {
        hunks.reduce(0) { $0 + $1.rows.filter { $0.kind == .added }.count }
    }
    var removedLines: Int {
        hunks.reduce(0) { $0 + $1.rows.filter { $0.kind == .removed }.count }
    }
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

    var kind: Kind
    var oldNumber: Int?
    var oldText: String?
    var newNumber: Int?
    var newText: String?

    // Syntax-coloured versions, filled in by DiffHighlighter after parsing.
    var oldHighlighted: AttributedString?
    var newHighlighted: AttributedString?

    var id: String { "\(kind.rawValue)-\(oldNumber ?? -1)-\(newNumber ?? -1)-\(oldText ?? "")\(newText ?? "")" }
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
                currentHunk?.rows.append(
                    DiffRow(
                        kind: kind,
                        oldNumber: removed?.0,
                        oldText: removed?.1,
                        newNumber: added?.0,
                        newText: added?.1
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
            if let file = currentFile {
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
        return Diff(files: files)
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
