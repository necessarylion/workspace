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

    /// UTF-16 offset where each line begins, `lineStarts[0]` always 0.
    ///
    /// tree-sitter wants an edit described in rows and columns as well as in
    /// offsets, and working one out used to mean walking the text from the very
    /// beginning — every keystroke, so a file of any size charged for its whole
    /// length on each letter typed near the bottom of it. Kept as a list
    /// instead: a row is a binary search, and an edit shifts the offsets after
    /// it rather than recounting them.
    private var lineStarts: [Int] = [0]
    /// One parser per embedded language, and the last block each one coloured —
    /// see ``embeddedHighlights(in:storage:)``.
    private var embeddedHighlighters: [String: TreeSitterHighlighter] = [:]
    private var embeddedCaptures: [String: (text: String, captures: [(range: NSRange, capture: String)])] = [:]
    /// Length of `text` in UTF-16, kept alongside so a point can be clamped to
    /// it without measuring the string again.
    private var textLength = 0

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
        text = newText

        guard let tree else {
            reparse()
            return
        }

        let startOffset = editedRange.location
        let newEndOffset = NSMaxRange(editedRange)
        let oldEndOffset = max(newEndOffset - delta, 0)

        // Read off the index while it still describes the text before the edit.
        let startPoint = point(at: startOffset)
        let oldEndPoint = point(at: oldEndOffset)
        let lineStart = lineStarts[row(at: startOffset)]

        // One pass over what was inserted, which answers both questions below:
        // where the new text ends, and which line starts now sit inside it.
        let breaks = Self.lineBreaks(
            in: newText,
            range: NSRange(location: startOffset, length: newEndOffset - startOffset)
        )
        let newEndPoint = Point(
            row: Int(startPoint.row) + breaks.count,
            column: (newEndOffset - (breaks.last.map { $0 + 1 } ?? lineStart)) * 2
        )

        replaceLineStarts(
            from: startOffset,
            oldEnd: oldEndOffset,
            newEnd: newEndOffset,
            inserted: breaks.map { $0 + 1 }
        )

        let edit = InputEdit(
            startByte: startOffset * 2,
            oldEndByte: oldEndOffset * 2,
            newEndByte: newEndOffset * 2,
            startPoint: startPoint,
            oldEndPoint: oldEndPoint,
            newEndPoint: newEndPoint
        )
        tree.edit(edit)
        self.tree = parser.parse(tree: tree, string: text)
    }

    private func reparse() {
        rebuildLineStarts()
        tree = parser.parse(tree: nil as MutableTree?, string: text)
    }

    // MARK: - Lines

    /// UTF-16 offsets of the newlines inside one range of a string. Only the
    /// range is looked at: everything outside it is unchanged by the edit.
    private static func lineBreaks(in text: String, range: NSRange) -> [Int] {
        guard range.length > 0 else { return [] }
        let region = (text as NSString).substring(with: range) as NSString

        var found: [Int] = []
        for index in 0..<region.length where region.character(at: index) == 0x0A {
            found.append(range.location + index)
        }
        return found
    }

    private func rebuildLineStarts() {
        var starts = [0]
        var offset = 0
        for unit in text.utf16 {
            offset += 1
            if unit == 0x0A { starts.append(offset) }
        }
        lineStarts = starts
        textLength = offset
    }

    /// The line `offset` sits on, counted from 0.
    private func row(at offset: Int) -> Int {
        // The last line start at or before the offset, so one before the first
        // that is past it. `lineStarts[0]` is 0, so this is never negative.
        var low = 0
        var high = lineStarts.count
        while low < high {
            let middle = (low + high) / 2
            if lineStarts[middle] > offset {
                high = middle
            } else {
                low = middle + 1
            }
        }
        return low - 1
    }

    private func point(at offset: Int) -> Point {
        // Clamped, because an edit can be reported against a longer text than
        // the one the index was built from if a change was ever missed, and a
        // point past the end would be a nonsense column rather than a crash.
        let offset = min(max(offset, 0), textLength)
        let row = row(at: offset)
        return Point(row: row, column: (offset - lineStarts[row]) * 2)
    }

    /// Moves the index over an edit: the line starts that fell inside the
    /// replaced text give way to the ones the new text brought, and everything
    /// after them slides by the difference in length.
    private func replaceLineStarts(from start: Int, oldEnd: Int, newEnd: Int, inserted: [Int]) {
        // A line start exactly at `start` is untouched — the newline that made
        // it sits before the edit, so the line still begins where it did.
        let first = firstLineStart(after: start)
        let last = firstLineStart(after: oldEnd)
        lineStarts.replaceSubrange(first..<last, with: inserted)

        let delta = newEnd - oldEnd
        textLength += delta
        guard delta != 0 else { return }
        for index in (first + inserted.count)..<lineStarts.count {
            lineStarts[index] += delta
        }
    }

    private func firstLineStart(after offset: Int) -> Int {
        row(at: offset) + 1
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

        // Embedded blocks last, so that where the host grammar has already said
        // something about the same span — `raw_text` is one flat token to HTML —
        // the inner language has the final word. Callers apply these in order.
        return resolveOverlaps(in: result) + embeddedHighlights(in: range, storage: storage)
    }

    // MARK: - Embedded languages

    /// Captures from the blocks of *another* language inside this file.
    ///
    /// A grammar stops at the boundary of its own language: to HTML the body of
    /// a `<script>` is one undifferentiated `raw_text` token, which is why a Vue
    /// single-file component came out with its whole script in the plain text
    /// colour. tree-sitter answers this with injections, which this highlighter
    /// does not implement; what it does instead is parse each block with a
    /// highlighter of its own and shift the ranges into this file.
    ///
    /// The result is cached against the block's text, so scrolling costs
    /// nothing and only an edit inside a block re-parses it.
    private func embeddedHighlights(
        in range: NSRange,
        storage: NSString
    ) -> [(range: NSRange, capture: String)] {
        guard language.id == .html, let tree, let root = tree.rootNode else { return [] }

        var result: [(range: NSRange, capture: String)] = []
        for block in embeddedBlocks(under: root, storage: storage) {
            // Only what is on screen, but whole blocks: a block is parsed as a
            // unit, and a half-parsed one would colour nothing.
            guard NSIntersectionRange(block.content, range).length > 0 else { continue }
            let text = storage.substring(with: block.content)
            for capture in captures(of: text, in: block.language) {
                let shifted = NSRange(
                    location: capture.range.location + block.content.location,
                    length: capture.range.length
                )
                result.append((shifted, capture.capture))
            }
        }
        return result
    }

    /// One `<script>` or `<style>` body, and what it is written in.
    private struct EmbeddedBlock {
        let language: CodeLanguage
        /// The text between the tags, not the element.
        let content: NSRange
    }

    /// Walks the element tree for `<script>` and `<style>` bodies.
    ///
    /// Descends through elements rather than reading only the top level, since a
    /// Vue component keeps its blocks at the root but an ordinary HTML page
    /// buries them in `<head>` or at the end of `<body>`.
    private func embeddedBlocks(under root: Node, storage: NSString) -> [EmbeddedBlock] {
        var blocks: [EmbeddedBlock] = []

        func walk(_ node: Node, depth: Int) {
            guard depth < 32 else { return }
            if let type = node.nodeType, type == "script_element" || type == "style_element" {
                if let block = block(for: node, isScript: type == "script_element", storage: storage) {
                    blocks.append(block)
                }
                return
            }
            for index in 0..<node.namedChildCount {
                guard let child = node.namedChild(at: index) else { continue }
                walk(child, depth: depth + 1)
            }
        }

        walk(root, depth: 0)
        return blocks
    }

    private func block(for element: Node, isScript: Bool, storage: NSString) -> EmbeddedBlock? {
        var content: NSRange?
        var startTag: NSRange?
        for index in 0..<element.childCount {
            guard let child = element.child(at: index), let type = child.nodeType else { continue }
            if type == "start_tag" { startTag = child.range }
            if type == "raw_text" { content = child.range }
        }
        guard let content, content.length > 0, NSMaxRange(content) <= storage.length else { return nil }

        var attribute: String?
        if let startTag, NSMaxRange(startTag) <= storage.length {
            attribute = Self.langAttribute(in: storage.substring(with: startTag))
        }
        guard let language = Self.embeddedLanguage(lang: attribute, isScript: isScript) else { return nil }
        return EmbeddedBlock(language: language, content: content)
    }

    /// The value of `lang="…"` in a start tag, which is how a single-file
    /// component says its `<script>` is TypeScript rather than JavaScript.
    private static func langAttribute(in tag: String) -> String? {
        guard let match = tag.range(
            of: #"\blang\s*=\s*["']?([A-Za-z0-9_+-]+)"#,
            options: [.regularExpression, .caseInsensitive]
        ) else { return nil }
        let text = String(tag[match])
        guard let value = text.range(of: #"[A-Za-z0-9_+-]+$"#, options: .regularExpression) else { return nil }
        return String(text[value]).lowercased()
    }

    /// A `lang` word (or its absence) to a grammar we actually have.
    ///
    /// The pre-processor dialects have no grammar of their own and are given the
    /// plain one instead: SCSS and Less are near enough to CSS that all it costs
    /// is the odd uncoloured token, which still reads better than one flat wall
    /// of text.
    private static func embeddedLanguage(lang: String?, isScript: Bool) -> CodeLanguage? {
        guard isScript else {
            switch lang {
            case nil, "css", "scss", "sass", "less", "postcss", "stylus": return .css
            default: return nil
            }
        }
        switch lang {
        case nil, "js", "javascript", "mjs", "cjs": return .javascript
        case "ts", "typescript", "mts", "cts": return .typescript
        case "tsx": return .tsx
        case "jsx": return .jsx
        default: return nil
        }
    }

    /// Parses one block, reusing both the parser and the last answer it gave.
    private func captures(
        of text: String,
        in language: CodeLanguage
    ) -> [(range: NSRange, capture: String)] {
        let id = language.id.rawValue
        if let cached = embeddedCaptures[id], cached.text == text { return cached.captures }

        let highlighter = embeddedHighlighters[id] ?? TreeSitterHighlighter(language: language)
        embeddedHighlighters[id] = highlighter
        highlighter.setText(text)
        guard highlighter.isReady else { return [] }

        let captures = highlighter.highlights(in: NSRange(location: 0, length: (text as NSString).length))
        embeddedCaptures[id] = (text: text, captures: captures)
        return captures
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
        // A YAML key is a scalar like any other, so the grammar's blanket
        // string rule claims it as well as the `property` rule meant for it —
        // and `string` outranks `property`, which leaves keys and values the
        // same colour, i.e. most of the file in one colour. The key is only a
        // string in the parser's sense; drop that capture and let `property`
        // stand.
        if language.id == .yaml, name.hasPrefix("string"), isMappingKey(capture.node) {
            return nil
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

    /// Whether a scalar is the key of a mapping rather than a value, told by
    /// the pair's own `key` field so both block (`name: value`) and flow
    /// (`{ name: value }`) mappings answer the same way.
    ///
    /// The scalar sits two or three levels under the pair — quoted scalars are
    /// a `flow_node` away, plain ones go through `plain_scalar` first.
    private func isMappingKey(_ node: Node) -> Bool {
        var child = node
        var ancestor = node.parent
        for _ in 0..<3 {
            guard let current = ancestor else { return false }
            if let key = current.child(byFieldName: "key") {
                return key.id == child.id
            }
            child = current
            ancestor = current.parent
        }
        return false
    }

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
