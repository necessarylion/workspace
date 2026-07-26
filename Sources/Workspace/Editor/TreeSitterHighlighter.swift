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
    ///
    /// Predicates are resolved, and that is not optional: a highlight query
    /// gives the same identifier half a dozen candidate captures — `constant`
    /// for an ALL-CAPS name, `variable.builtin` for `this`, `function.builtin`
    /// for a known global — and leaves it to `#match?` and `#eq?` to throw away
    /// the ones that do not fit. Skip them and every identifier arrives wearing
    /// all six, with the last one to be enumerated deciding its colour.
    func highlights(in range: NSRange) -> [(range: NSRange, capture: String)] {
        guard let query, let tree, let root = tree.rootNode else { return [] }

        let cursor = query.execute(node: root, in: tree)
        cursor.setRange(range)
        cursor.matchLimit = 256

        let storage = text as NSString
        let context = Predicate.Context(string: text)

        var result: [(range: NSRange, capture: String)] = []
        for match in cursor.resolve(with: context) {
            for capture in match.captures {
                guard let name = capture.name, capture.range.length > 0 else { continue }
                guard let refined = refine(name, at: capture, in: storage) else { continue }
                result.append((capture.range, refined))
            }
        }
        return resolveOverlaps(in: result)
    }

    /// Where several captures land on exactly the same token, keeps the one
    /// that says the most about it.
    ///
    /// Predicates thin the candidates out but cannot settle every case: the
    /// same identifier is `variable.parameter` to one pattern and plain
    /// `variable` to another, and both are true. Leaving it to enumeration
    /// order means the answer depends on where a rule sits in a query file,
    /// which is how parameters ended up the colour of ordinary variables.
    /// Ranges that merely overlap are left alone — `string.escape` inside a
    /// `string` is a smaller range, and still meant to win.
    private func resolveOverlaps(
        in captures: [(range: NSRange, capture: String)]
    ) -> [(range: NSRange, capture: String)] {
        var best: [NSRange: (index: Int, capture: String)] = [:]
        var order: [NSRange] = []

        for (index, entry) in captures.enumerated() {
            guard let existing = best[entry.range] else {
                best[entry.range] = (index, entry.capture)
                order.append(entry.range)
                continue
            }
            if Self.rank(of: entry.capture) > Self.rank(of: existing.capture) {
                best[entry.range] = (existing.index, entry.capture)
            }
        }

        return order.compactMap { range in
            best[range].map { (range: range, capture: $0.capture) }
        }
    }

    /// How much a capture is worth when two of them describe the same token.
    ///
    /// `variable` is deliberately at the bottom: every identifier is one, so
    /// anything more specific that also matched is the better answer — except
    /// where the grammar's guess is worse than "a name", which is why `type`
    /// and `constructor` sit below it. An identifier only gets those two
    /// alongside `variable` when the pattern behind them was a guess from the
    /// capital letter; a real type annotation is a different node, and comes
    /// with no competition at all.
    private static func rank(of capture: String) -> Int {
        switch capture.split(separator: ".").first.map(String.init) ?? capture {
        case "keyword", "include", "storageclass", "conditional", "repeat", "exception":
            return 100
        case "comment", "string", "number", "float", "boolean", "character":
            return 90
        case "variable" where capture != "variable":
            // variable.builtin, variable.parameter, variable.member …
            return 80
        case "function", "method", "constant", "attribute", "label", "tag":
            return 70
        case "property", "field":
            return 60
        case "variable":
            return 50
        case "type", "constructor", "namespace", "module":
            return 40
        default:
            return 30
        }
    }

    /// Narrows a capture the grammar left broad, or drops it entirely.
    private func refine(_ name: String, at capture: QueryCapture, in storage: NSString) -> String? {
        if name.hasPrefix("string"), isModulePath(capture.node) {
            return "string.import"
        }
        // Grammars hand back one flat `keyword` for words an editor colours
        // very differently — `import` is control flow, `private` is a storage
        // modifier. The word itself is the only thing that tells them apart.
        if name == "keyword", NSMaxRange(capture.range) <= storage.length {
            return Self.keywordCaptures[storage.substring(with: capture.range)] ?? name
        }
        // A capital letter is all most grammars ask for before calling a name a
        // constructor, which makes every imported class one. Only a `new` in
        // front of it actually says so.
        if name == "constructor", capture.node.parent?.nodeType != "new_expression" {
            return nil
        }
        return name
    }

    /// Which capture a bare keyword really deserves, by the word itself.
    ///
    /// The split follows what TextMate grammars do, because that is what the
    /// themes we import are written against: control flow is one colour,
    /// declarations and modifiers another, word-shaped operators a third.
    private static let keywordCaptures: [String: String] = {
        var captures: [String: String] = [:]
        for word in ["import", "export", "from", "include", "require", "use"] {
            captures[word] = "include"
        }
        for word in ["if", "else", "elif", "switch", "case", "default", "when", "match", "guard", "unless"] {
            captures[word] = "conditional"
        }
        for word in ["for", "while", "do", "loop", "foreach", "repeat"] {
            captures[word] = "repeat"
        }
        for word in ["try", "catch", "finally", "throw", "throws", "raise", "rescue", "except"] {
            captures[word] = "exception"
        }
        for word in ["return", "yield", "await", "break", "continue", "goto", "defer"] {
            captures[word] = "keyword.return"
        }
        for word in [
            "class", "struct", "enum", "interface", "protocol", "trait", "impl", "extension",
            "type", "typealias", "const", "let", "var", "val", "function", "func", "fn", "def",
            "static", "public", "private", "protected", "internal", "readonly", "abstract",
            "declare", "async", "override", "final", "extends", "implements", "namespace",
            "module", "package", "mut", "pub"
        ] {
            captures[word] = "storageclass"
        }
        for word in ["typeof", "instanceof", "keyof", "delete", "new", "satisfies", "as", "is", "in", "of"] {
            captures[word] = "keyword.operator"
        }
        return captures
    }()

    /// Whether a string node is the module an import names, rather than an
    /// ordinary string. Grammars capture both as `string`, so the distinction
    /// comes from the node's ancestors: the statement itself, or the argument
    /// list of a `require()` / `import()` call.
    private func isModulePath(_ node: Node) -> Bool {
        let statements: Set<String> = [
            "import_statement",       // JS/TS: import x from '…'
            "export_statement",       // JS/TS: export … from '…'
            "import_require_clause",  // TS: import x = require('…')
            "import_declaration",     // Go, and TS type-only imports
            "import_spec"             // Go: one entry of an import block
        ]

        var ancestor = node.parent
        // The string sits a couple of levels under the statement at most:
        // string → arguments/spec → statement.
        for _ in 0..<3 {
            guard let current = ancestor, let type = current.nodeType else { return false }
            if statements.contains(type) { return true }
            if type == "call_expression", isModuleCall(current) { return true }
            ancestor = current.parent
        }
        return false
    }

    /// `require('…')` and dynamic `import('…')`, told apart from any other call
    /// by the callee's own text.
    private func isModuleCall(_ call: Node) -> Bool {
        guard let callee = call.child(at: 0) else { return false }
        let storage = text as NSString
        let range = callee.range
        guard NSMaxRange(range) <= storage.length else { return false }
        let name = storage.substring(with: range)
        return name == "require" || name == "import"
    }

    /// The innermost named node at an offset — used for ⌘-hover feedback.
    func nodeDescription(at offset: Int) -> String? {
        guard let tree, let root = tree.rootNode else { return nil }
        let byte = UInt32(offset * 2)
        guard let node = root.descendant(in: byte..<(byte + 2)) else { return nil }
        return node.nodeType
    }
}
