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
        var result = diff
        // One parser per language, reused across the diff's files.
        var highlighters: [String: TreeSitterHighlighter] = [:]

        for fileIndex in result.files.indices {
            let file = result.files[fileIndex]
            guard !file.isBinary else { continue }

            let language = CodeLanguage.detectLanguageFrom(
                url: URL(fileURLWithPath: file.newPath)
            )
            guard language.id != CodeLanguage.default.id else { continue }

            let key = language.id.rawValue
            let highlighter = highlighters[key] ?? TreeSitterHighlighter(language: language)
            highlighters[key] = highlighter

            for hunkIndex in result.files[fileIndex].hunks.indices {
                colour(
                    rows: &result.files[fileIndex].hunks[hunkIndex].rows,
                    side: .old,
                    using: highlighter
                )
                colour(
                    rows: &result.files[fileIndex].hunks[hunkIndex].rows,
                    side: .new,
                    using: highlighter
                )
            }
        }
        return result
    }

    private enum Side { case old, new }

    private static func colour(
        rows: inout [DiffRow],
        side: Side,
        using highlighter: TreeSitterHighlighter
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

        // UTF-16 start offset of every line inside the snippet.
        var lineStarts: [Int] = []
        var offset = 0
        for line in lines {
            lineStarts.append(offset)
            offset += (line as NSString).length + 1
        }

        let attributed = lines.map { NSMutableAttributedString(string: $0) }
        let fullRange = NSRange(location: 0, length: (snippet as NSString).length)
        for capture in highlighter.highlights(in: fullRange) {
            guard let color = SyntaxTheme.captureColor(for: capture.capture) else { continue }
            var lineIndex = lineStarts.lastIndex { $0 <= capture.range.location } ?? 0
            let captureEnd = NSMaxRange(capture.range)
            // A capture can span line breaks; colour every line it touches.
            while lineIndex < lines.count, lineStarts[lineIndex] < captureEnd {
                let lineRange = NSRange(
                    location: lineStarts[lineIndex],
                    length: (lines[lineIndex] as NSString).length
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
}
