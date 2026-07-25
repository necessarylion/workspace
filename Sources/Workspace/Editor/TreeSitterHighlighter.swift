import AppKit
import CodeEditLanguages
import SwiftTreeSitter

/// Syntax highlighting driven by tree-sitter.
///
/// The parser is fed the text view's own storage in UTF-16, which is what
/// tree-sitter calls `TSInputEncodingUTF16LE`. That matters: with UTF-16 the
/// byte offsets tree-sitter reports convert to `NSRange` by a plain divide by
/// two, so no offset translation is needed anywhere else.
@MainActor
final class TreeSitterHighlighter {
    private(set) var language: CodeLanguage
    private var parser = Parser()
    private var query: Query?
    private var tree: MutableTree?
    private var text: String = ""

    var isReady: Bool { query != nil && tree != nil }

    init(language: CodeLanguage) {
        self.language = language
        load(language)
    }

    /// Switches languages, e.g. when the same editor is reused for another file.
    func setLanguage(_ language: CodeLanguage) {
        guard language.id != self.language.id else { return }
        self.language = language
        parser = Parser()
        tree = nil
        load(language)
        if !text.isEmpty {
            reparse()
        }
    }

    private func load(_ language: CodeLanguage) {
        query = nil
        guard let tsLanguage = language.language else { return }
        try? parser.setLanguage(tsLanguage)
        query = TreeSitterModel.shared.query(for: language.id)
    }

    // MARK: - Text lifecycle

    func setText(_ newText: String) {
        text = newText
        tree = nil
        reparse()
    }

    /// Applies one edit, then reparses using the old tree so tree-sitter only
    /// re-does the part of the file that actually changed.
    func apply(
        editedRange: NSRange,
        changeInLength delta: Int,
        newText: String
    ) {
        let oldText = text
        text = newText

        guard let tree else {
            reparse()
            return
        }

        let startOffset = editedRange.location
        let newEndOffset = NSMaxRange(editedRange)
        let oldEndOffset = max(newEndOffset - delta, 0)

        // One pass over the unchanged prefix gives the start point; the old end
        // point continues that same pass.
        var scanner = LineScanner(oldText)
        scanner.advance(to: startOffset)
        let startPoint = scanner.point
        var oldEndScanner = scanner
        oldEndScanner.advance(to: oldEndOffset)

        let edit = InputEdit(
            startByte: startOffset * 2,
            oldEndByte: oldEndOffset * 2,
            newEndByte: newEndOffset * 2,
            startPoint: startPoint,
            oldEndPoint: oldEndScanner.point,
            newEndPoint: Self.point(
                afterReplacing: NSRange(location: startOffset, length: newEndOffset - startOffset),
                in: newText,
                startingAt: startPoint,
                lineStart: scanner.lineStart
            )
        )
        tree.edit(edit)
        self.tree = parser.parse(tree: tree, string: text)
    }

    private func reparse() {
        tree = parser.parse(tree: nil as MutableTree?, string: text)
    }

    /// End point of freshly inserted text. Only the inserted region is scanned:
    /// everything before the edit is identical in both versions.
    private static func point(
        afterReplacing range: NSRange,
        in newText: String,
        startingAt startPoint: Point,
        lineStart: Int
    ) -> Point {
        let inserted = (newText as NSString).substring(with: range) as NSString
        var row = Int(startPoint.row)
        var lastBreak = -1
        for index in 0..<inserted.length where inserted.character(at: index) == 0x0A {
            row += 1
            lastBreak = index
        }
        let column = lastBreak >= 0
            ? inserted.length - (lastBreak + 1)
            : NSMaxRange(range) - lineStart
        return Point(row: row, column: column * 2)
    }

    /// Walks a string once, tracking the line and line start for an offset.
    private struct LineScanner {
        private var iterator: String.UTF16View.Iterator
        private(set) var offset = 0
        private(set) var row = 0
        private(set) var lineStart = 0

        init(_ string: String) {
            iterator = string.utf16.makeIterator()
        }

        mutating func advance(to target: Int) {
            while offset < target, let unit = iterator.next() {
                offset += 1
                if unit == 0x0A {
                    row += 1
                    lineStart = offset
                }
            }
        }

        var point: Point {
            Point(row: row, column: (offset - lineStart) * 2)
        }
    }

    // MARK: - Highlighting

    /// Capture ranges inside `range`, in the order tree-sitter finds them.
    ///
    /// Later captures win when they overlap, which is how nested captures like
    /// `string` containing `string.escape` are meant to render.
    func highlights(in range: NSRange) -> [(range: NSRange, capture: String)] {
        guard let query, let tree, let root = tree.rootNode else { return [] }

        let cursor = query.execute(node: root, in: tree)
        cursor.setRange(range)
        cursor.matchLimit = 256

        var result: [(range: NSRange, capture: String)] = []
        for match in cursor {
            for capture in match.captures {
                guard let name = capture.name, capture.range.length > 0 else { continue }
                result.append((capture.range, name))
            }
        }
        return result
    }

    /// The innermost named node at an offset — used for ⌘-hover feedback.
    func nodeDescription(at offset: Int) -> String? {
        guard let tree, let root = tree.rootNode else { return nil }
        let byte = UInt32(offset * 2)
        guard let node = root.descendant(in: byte..<(byte + 2)) else { return nil }
        return node.nodeType
    }
}
