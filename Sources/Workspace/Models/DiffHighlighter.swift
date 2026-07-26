import AppKit
import CodeEditLanguages
import Foundation

/// Adds syntax colours to a parsed diff.
///
/// Each hunk side (old / new) is joined into one snippet and parsed with the
/// same tree-sitter setup the editor uses. Tree-sitter is error-tolerant, so
/// keywords, strings and comments still resolve even though a hunk is only a
/// fragment of the file.
@MainActor
enum DiffHighlighter {
    static func highlight(_ diff: Diff) -> Diff {
        // A diff of many files is left plain here and coloured a file at a time
        // as the reader opens it — see `Diff.fileByFileThreshold` and
        // `highlight(_ file:)`. Doing all of them up front freezes the window
        // for as long as the parse takes.
        guard !diff.isFileByFile else { return diff }

        var result = diff
        // One parser per language, reused across the diff's files.
        var highlighters: [String: TreeSitterHighlighter] = [:]
        var colours = ColourCache()
        for fileIndex in result.files.indices {
            colour(file: &result.files[fileIndex], using: &highlighters, colours: &colours)
        }
        return result
    }

    /// One file of a diff coloured on its own, for the diffs `highlight(_:)`
    /// deliberately leaves plain.
    static func highlight(_ file: DiffFile) -> DiffFile {
        var result = file
        var highlighters: [String: TreeSitterHighlighter] = [:]
        var colours = ColourCache()
        colour(file: &result, using: &highlighters, colours: &colours)
        return result
    }

    /// Capture name → colour, for the length of one run.
    ///
    /// Resolving a name walks it back a dot at a time and rebuilds the string at
    /// each step, and a diff asks the same few dozen questions tens of thousands
    /// of times. Kept local rather than on the palette so that changing the
    /// theme needs no invalidation: the next diff starts with an empty one.
    @MainActor
    private struct ColourCache {
        private var colours: [String: NSColor?] = [:]

        mutating func colour(for capture: String) -> NSColor? {
            if let known = colours[capture] { return known }
            let colour = SyntaxTheme.captureColor(for: capture)
            colours[capture] = colour
            return colour
        }
    }

    private static func colour(
        file: inout DiffFile,
        using highlighters: inout [String: TreeSitterHighlighter],
        colours: inout ColourCache
    ) {
        guard !file.isBinary else { return }

        let language = CodeLanguage.forFile(url: URL(fileURLWithPath: file.newPath))
        guard language.id != CodeLanguage.default.id else { return }

        let key = language.id.rawValue
        let highlighter = highlighters[key] ?? TreeSitterHighlighter(language: language)
        highlighters[key] = highlighter

        for hunkIndex in file.hunks.indices {
            colour(rows: &file.hunks[hunkIndex].rows, side: .old, using: highlighter, colours: &colours)
            colour(rows: &file.hunks[hunkIndex].rows, side: .new, using: highlighter, colours: &colours)
        }
    }

    private enum Side { case old, new }

    private static func colour(
        rows: inout [DiffRow],
        side: Side,
        using highlighter: TreeSitterHighlighter,
        colours: inout ColourCache
    ) {
        // Collect the lines this side actually shows, remembering which row
        // each one came from.
        var rowIndices: [Int] = []
        var lines: [String] = []
        for (index, row) in rows.enumerated() {
            if let text = side == .old ? row.oldText : row.newText {
                rowIndices.append(index)
                lines.append(text)
            }
        }
        guard !lines.isEmpty else { return }

        let snippet = lines.joined(separator: "\n")
        highlighter.setText(snippet)
        guard highlighter.isReady else { return }

        // UTF-16 start offset and length of every line inside the snippet.
        // Measured once: bridging a line to `NSString` for its length inside the
        // capture loop below charged for it again on every capture that touched
        // it.
        var lineStarts: [Int] = []
        var lineLengths: [Int] = []
        lineStarts.reserveCapacity(lines.count)
        lineLengths.reserveCapacity(lines.count)
        var offset = 0
        for line in lines {
            let length = (line as NSString).length
            lineStarts.append(offset)
            lineLengths.append(length)
            offset += length + 1
        }

        let attributed = lines.map { NSMutableAttributedString(string: $0) }
        let fullRange = NSRange(location: 0, length: (snippet as NSString).length)
        for capture in highlighter.highlights(in: fullRange) {
            guard let color = colours.colour(for: capture.capture) else { continue }
            var lineIndex = lineIndex(of: capture.range.location, in: lineStarts)
            let captureEnd = NSMaxRange(capture.range)
            // A capture can span line breaks; colour every line it touches.
            while lineIndex < lines.count, lineStarts[lineIndex] < captureEnd {
                let lineRange = NSRange(
                    location: lineStarts[lineIndex],
                    length: lineLengths[lineIndex]
                )
                let overlap = NSIntersectionRange(capture.range, lineRange)
                if overlap.length > 0 {
                    attributed[lineIndex].addAttribute(
                        .foregroundColor,
                        value: color,
                        range: NSRange(
                            location: overlap.location - lineRange.location,
                            length: overlap.length
                        )
                    )
                }
                lineIndex += 1
            }
        }

        for (position, rowIndex) in rowIndices.enumerated() {
            let text = AttributedString(attributed[position])
            switch side {
            case .old: rows[rowIndex].oldHighlighted = text
            case .new: rows[rowIndex].newHighlighted = text
            }
        }
    }

    /// The line a UTF-16 offset falls on.
    ///
    /// `lineStarts` is ascending, so this is a binary search. It used to be
    /// `lastIndex(where:)`, which scans from the end of the array — so a hunk of
    /// a few hundred lines walked nearly all of them for every capture near its
    /// top, and colouring one hunk cost the square of its length.
    private static func lineIndex(of location: Int, in lineStarts: [Int]) -> Int {
        var low = 0
        var high = lineStarts.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if lineStarts[middle] <= location {
                low = middle
            } else {
                high = middle - 1
            }
        }
        return low
    }
}
