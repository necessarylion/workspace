import Foundation
import Markdown

/// Where a `#123` and an `@name` point, when the document came from somewhere
/// that gives them a meaning. A `.md` file opened on its own has a repository
/// behind it too — a README's `#12` is that repository's pull request.
struct MarkdownLinks: Hashable, Sendable {
    var remote: RemoteInfo?

    static let none = MarkdownLinks()

    init(remote: RemoteInfo? = nil) { self.remote = remote }

    func pullRequest(_ number: Int) -> URL? { remote?.pullRequestURL(number: number) }

    func user(_ name: String) -> URL? {
        guard let remote else { return nil }
        switch remote.kind {
        case .github: return URL(string: "https://github.com/\(name)")
        case .bitbucket: return URL(string: "https://bitbucket.org/\(name)/")
        case .unknown: return nil
        }
    }
}

/// The Markdown parse: cmark-gfm's block tree, walked into the blocks
/// `MarkdownText` draws.
///
/// The parser this replaced read one source line at a time, and every gap it
/// had was the same gap — there was no tree. A paragraph hard-wrapped at 80
/// columns came out as a ladder of paragraphs; a continuation line under a
/// bullet lost its bullet; a fence inside a list item was hoisted out of it;
/// `Title` over `=====` was a paragraph and a rule. None of that is answered
/// here, because none of it is a question any more: it is what
/// `swift-markdown` hands over, and the whole of this file is the walk from its
/// nodes to ours. See `Docs/Markdown.md`.
///
/// Three things the tree does *not* answer, and each has its place below: HTML
/// arrives raw (`MarkdownHTMLText`), footnotes are read as link reference
/// definitions and have to be caught rather than passed through, and bare URLs,
/// `:tada:`, `#123` and `@name` are one scan over the text (`MarkdownInline`).
enum MarkdownParser {
    static func blocks(in text: String, links: MarkdownLinks) -> [MarkdownText.Block] {
        var builder = Builder(links: links)
        var blocks = builder.blocks(of: Document(parsing: text))
        blocks += builder.footnoteBlocks()
        return blocks
    }
}

// MARK: - The walk

private struct Builder {
    typealias Block = MarkdownText.Block

    let links: MarkdownLinks

    /// `[^1]: …` definitions, lifted out of the flow and printed at the end the
    /// way both hosts print them.
    private var footnotes: [(label: String, text: String)] = []
    /// How deep the loose HTML has been re-read as a document of its own. Only
    /// a backstop: `MarkdownHTMLText` drops the tags that could nest.
    private var depth = 0

    init(links: MarkdownLinks) { self.links = links }

    /// One picture, on its way out of the line it was written in.
    private struct Picture {
        var url: String
        var alt: String
        var width: CGFloat?
    }

    // MARK: Blocks

    mutating func blocks(of parent: Markup) -> [Block] {
        var stack = ContainerStack()
        for child in parent.children { append(child, to: &stack) }
        return stack.finish()
    }

    private mutating func append(_ markup: Markup, to stack: inout ContainerStack) {
        switch markup {
        case let node as Paragraph:
            appendParagraph(node, skipping: 0, to: &stack)
        case let node as Heading:
            let text = inlineText(of: node)
            guard !text.isEmpty else { return }
            stack.append(.heading(level: min(max(node.level, 1), 6), text: text))
        case let node as CodeBlock:
            appendCode(node, to: &stack)
        case let node as HTMLBlock:
            appendHTML(node.rawHTML, to: &stack)
        case let node as BlockQuote:
            appendQuote(node, to: &stack)
        case let node as UnorderedList:
            stack.append(.list(list(node, isOrdered: false, start: 1)))
        case let node as OrderedList:
            stack.append(.list(list(node, isOrdered: true, start: Int(node.startIndex))))
        case is ThematicBreak:
            stack.append(.rule)
        case let node as Table:
            stack.append(table(node))
        default:
            // A node with no shape of its own here — a doxygen block, a custom
            // one — is whatever is inside it.
            for child in markup.children { append(child, to: &stack) }
        }
    }

    private mutating func appendCode(_ node: CodeBlock, to stack: inout ContainerStack) {
        // cmark keeps the newline that closed the fence; the view draws it as
        // an empty last line.
        let code = node.code.hasSuffix("\n") ? String(node.code.dropLast()) : node.code
        // ```swift title="x" — the word is the language, the rest is a host's.
        let language = node.language?
            .trimmingCharacters(in: .whitespaces)
            .split(separator: " ").first
            .map(String.init) ?? ""
        if language.lowercased() == "mermaid", !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            stack.append(.mermaid(code))
        } else {
            stack.append(.code(language: language, text: code))
        }
    }

    /// `skipping` leaves the first inline nodes out — it is how a GitHub
    /// alert's `[!WARNING]` marker is dropped without being drawn.
    private mutating func appendParagraph(_ node: Paragraph, skipping: Int, to stack: inout ContainerStack) {
        if skipping == 0, let notes = footnotes(in: node) {
            footnotes += notes
            return
        }
        var state = InlineState()
        var children = Array(node.children.dropFirst(skipping))
        // The break that followed the marker would otherwise open the line.
        if skipping > 0, children.first is SoftBreak || children.first is LineBreak {
            children.removeFirst()
        }
        for child in children { write(child, into: &state) }

        let text = state.text.trimmingCharacters(in: .whitespaces)
        if !text.isEmpty { stack.append(.paragraph(text)) }
        // A picture is a block of its own: `AttributedString` would swallow the
        // whole `![…](…)` and draw nothing, and a screenshot in the middle of a
        // sentence is not something a line of text can hold anyway.
        for picture in state.pictures {
            stack.append(.image(url: picture.url, alt: picture.alt, width: picture.width))
        }
    }

    private mutating func appendQuote(_ node: BlockQuote, to stack: inout ContainerStack) {
        var inner = ContainerStack()
        var alert: MarkdownText.Alert?
        for (index, child) in node.children.enumerated() {
            // `> [!WARNING]` — a marker on a line of its own, which is exactly
            // what the tree says it is: the first `Text` of the first paragraph.
            if index == 0, let paragraph = child as? Paragraph,
               let first = paragraph.child(at: 0) as? Text,
               let marked = MarkdownText.Alert(marker: first.string.trimmingCharacters(in: .whitespaces)) {
                alert = marked
                appendParagraph(paragraph, skipping: 1, to: &inner)
                continue
            }
            append(child, to: &inner)
        }
        let blocks = inner.finish()
        guard alert != nil || !blocks.isEmpty else { return }
        stack.append(.quote(alert, blocks))
    }

    private mutating func list(_ node: Markup, isOrdered: Bool, start: Int) -> MarkdownList {
        var items: [MarkdownList.Item] = []
        for case let item as ListItem in node.children {
            items.append(
                MarkdownList.Item(
                    isDone: item.checkbox.map { $0 == .checked },
                    // 1-based, and into the document as it was handed to us —
                    // which is what lets a tick be written back to the right
                    // `[ ]`, and the reason comments are dropped from the tree
                    // rather than cut out of the text beforehand.
                    //
                    // Nothing at all below the top level, and that is not a
                    // nicety: `depth` counts the loose HTML re-read as a
                    // document of its own, and cmark numbers *that* document
                    // from its own first line. A box in there would name a line
                    // in the snippet and a tick would be written over whatever
                    // happens to sit on that line of the real one. Undrawable
                    // is the right answer; corrupting the document is not.
                    line: depth == 0 ? item.range?.lowerBound.line : nil,
                    blocks: blocks(of: item)
                )
            )
        }
        return MarkdownList(isOrdered: isOrdered, start: start, items: items)
    }

    private mutating func table(_ node: Table) -> Block {
        var headers: [String] = []
        if let head = node.children.first(where: { $0 is Table.Head }) {
            for case let cell as Table.Cell in head.children { headers.append(inlineText(of: cell)) }
        }
        var rows: [[String]] = []
        if let body = node.children.first(where: { $0 is Table.Body }) {
            for case let row as Table.Row in body.children {
                rows.append(row.children.compactMap { ($0 as? Table.Cell).map { inlineText(of: $0) } })
            }
        }
        let width = max(headers.count, rows.map(\.count).max() ?? 0)
        let alignments = (0..<width).map { column -> MarkdownColumn in
            guard column < node.columnAlignments.count else { return .leading }
            switch node.columnAlignments[column] {
            case .left: return .leading
            case .center: return .center
            case .right: return .trailing
            case nil: return .leading
            }
        }
        return .table(
            headers: headers + Array(repeating: "", count: width - headers.count),
            rows: rows.map { $0 + Array(repeating: "", count: width - $0.count) },
            alignments: alignments
        )
    }

    // MARK: HTML

    /// cmark hands `<details>` over as **three siblings** — the open tag, the
    /// Markdown inside it (parsed properly, as Markdown), the close tag — so
    /// there is nothing to recurse into. `ContainerStack` is what turns that
    /// flat stream back into a section, and `MarkdownHTMLText` is what reads one
    /// raw block into the events it keeps.
    private mutating func appendHTML(_ rawHTML: String, to stack: inout ContainerStack) {
        for event in MarkdownHTMLText.events(in: rawHTML) {
            switch event {
            case .open(let container):
                stack.open(container)
            case .close(let container):
                stack.close(container)
            case .summary(let text):
                stack.setSummary(text)
            case .table(let headers, let rows):
                stack.append(
                    .table(
                        headers: headers,
                        rows: rows,
                        alignments: Array(repeating: .leading, count: headers.count)
                    )
                )
            case .markdown(let text):
                guard depth < 6 else { continue }
                depth += 1
                let nested = blocks(of: Document(parsing: text))
                depth -= 1
                for block in nested { stack.append(block) }
            }
        }
    }

    // MARK: Footnotes

    /// The `[^1]: the note` definitions in a paragraph, when cmark left them as
    /// one — which is what it does with a run of them, because a line break
    /// between two lines of prose is a soft break and nothing more.
    ///
    /// It often does not leave them at all: a definition whose note is a single
    /// word is a valid *link reference definition*, so cmark eats the line and
    /// turns every `[^1]` into a link pointing at the note's text. That half is
    /// caught in `write(link:into:)`, where such a link is drawn as the marker
    /// it was.
    private mutating func footnotes(in node: Paragraph) -> [(label: String, text: String)]? {
        guard let first = node.child(at: 0) as? Text, definition(in: first.string) != nil else {
            return nil
        }

        // A paragraph of definitions is a run of lines, and the tree holds them
        // as one list with breaks in it.
        var lines: [[Markup]] = [[]]
        for child in node.children {
            if child is SoftBreak || child is LineBreak {
                lines.append([])
            } else {
                lines[lines.count - 1].append(child)
            }
        }

        var notes: [(label: String, text: String)] = []
        for line in lines {
            var rest = line
            var state = InlineState(imagesAsText: true)
            var label: String?
            if let text = rest.first as? Text, let found = definition(in: text.string) {
                label = found.label
                rest.removeFirst()
                write(text: found.rest, into: &state)
            }
            for child in rest { write(child, into: &state) }
            let body = state.text.trimmingCharacters(in: .whitespaces)

            if let label {
                notes.append((label, body))
            } else if !notes.isEmpty, !body.isEmpty {
                // A note wrapped onto a second line.
                notes[notes.count - 1].text += " " + body
            }
        }
        return notes.isEmpty ? nil : notes
    }

    /// `[^label]: …` at the front of a line, and what follows it.
    private func definition(in raw: String) -> (label: String, rest: String)? {
        guard raw.hasPrefix("[^"), let close = raw.firstIndex(of: "]"),
              let colon = raw.index(close, offsetBy: 1, limitedBy: raw.endIndex),
              colon < raw.endIndex, raw[colon] == ":"
        else { return nil }
        let label = String(raw[raw.index(raw.startIndex, offsetBy: 2)..<close])
        guard !label.isEmpty else { return nil }
        return (label, String(raw[raw.index(after: colon)...]))
    }

    /// The notes, under a rule at the end of the document — where both hosts
    /// put them, whatever line they were written on.
    mutating func footnoteBlocks() -> [Block] {
        guard !footnotes.isEmpty else { return [] }
        return [.rule] + footnotes.map { note in
            .paragraph("**\\[\(MarkdownInline.escaping(note.label))\\]** \(note.text)")
        }
    }

    // MARK: Inline

    private struct InlineState {
        var text = ""
        var pictures: [Picture] = []
        /// A picture becomes its alt text rather than a block of its own: a
        /// heading, a table cell and a footnote have nowhere to put one.
        var imagesAsText = false
        /// Inside a link, where nothing is made a link a second time.
        var linkDepth = 0
        /// Addresses of the `<a>` tags still open. It lives here rather than in
        /// `write(html:into:)` because cmark hands the opening tag, the words
        /// and the closing tag over as three separate nodes — a stack that
        /// started again at each of them would never close a link.
        var openHTMLLinks: [String] = []
        /// Bitbucket hangs `{: data-layout='center' }` off an image, and that is
        /// also where a width lifted off an `<img>` is written. The next text
        /// node is where it lands.
        var expectsAttributes = false

        init(imagesAsText: Bool = false) { self.imagesAsText = imagesAsText }
    }

    /// Everything inside `parent` as one Markdown string, pictures included as
    /// their alt text.
    private mutating func inlineText(of parent: Markup) -> String {
        var state = InlineState(imagesAsText: true)
        for child in parent.children { write(child, into: &state) }
        return state.text.trimmingCharacters(in: .whitespaces)
    }

    private mutating func write(_ markup: Markup, into state: inout InlineState) {
        switch markup {
        case let node as Text:
            write(text: node.string, into: &state)
        case is SoftBreak:
            // A hard-wrapped paragraph is one paragraph, and the wrap is a
            // space — which is the whole of the biggest gap the line parser had.
            state.expectsAttributes = false
            state.text += " "
        case is LineBreak:
            state.expectsAttributes = false
            state.text += "\n"
        case let node as InlineCode:
            state.expectsAttributes = false
            state.text += MarkdownInline.codeSpan(node.code)
        case let node as InlineHTML:
            write(html: node.rawHTML, into: &state)
        case is Emphasis:
            write(markup: markup, wrappedIn: "*", into: &state)
        case is Strong:
            write(markup: markup, wrappedIn: "**", into: &state)
        case is Strikethrough:
            write(markup: markup, wrappedIn: "~~", into: &state)
        case let node as Link:
            write(link: node, into: &state)
        case let node as Image:
            write(image: node.source ?? "", alt: node.plainText, into: &state)
        case let node as SymbolLink:
            state.expectsAttributes = false
            state.text += MarkdownInline.codeSpan(node.destination ?? "")
        default:
            state.expectsAttributes = false
            for child in markup.children { write(child, into: &state) }
        }
    }

    private mutating func write(text raw: String, into state: inout InlineState) {
        var source = raw
        if state.expectsAttributes {
            state.expectsAttributes = false
            source = takingAttributes(from: source, into: &state)
        }
        state.text += MarkdownInline.decorated(source, links: links, inLink: state.linkDepth > 0)
    }

    private mutating func write(markup: Markup, wrappedIn fence: String, into state: inout InlineState) {
        state.expectsAttributes = false
        let before = state.text
        state.text = ""
        for child in markup.children { write(child, into: &state) }
        let body = state.text
        state.text = before + (body.isEmpty ? "" : fence + body + fence)
    }

    private mutating func write(link node: Link, into state: inout InlineState) {
        state.expectsAttributes = false
        // A footnote reference, mangled into a link by the reference-definition
        // rule. Drawn as the marker rather than as a link to the note's words.
        let label = node.plainText
        if label.hasPrefix("^"), label.dropFirst().allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) {
            state.text += MarkdownInline.escaping("[\(label.dropFirst())]")
            return
        }

        let before = state.text
        let pictures = state.pictures.count
        state.text = ""
        state.linkDepth += 1
        for child in node.children { write(child, into: &state) }
        state.linkDepth -= 1
        let body = state.text
        state.text = before

        guard let destination = node.destination, !destination.isEmpty else {
            state.text += body
            return
        }
        guard !body.isEmpty else {
            // `[![badge](…)](…)` — the picture *is* the link, and it has been
            // taken out of the line. Writing the address after it would leave a
            // bare URL under every badge in a README.
            guard state.pictures.count == pictures else { return }
            state.text += "<\(destination)>"
            return
        }
        state.text += "[\(body)](\(MarkdownInline.destination(destination)))"
    }

    private mutating func write(image source: String, alt: String, into state: inout InlineState) {
        state.expectsAttributes = false
        guard !source.isEmpty else { return }
        guard !state.imagesAsText else {
            state.text += MarkdownInline.escaping(alt)
            return
        }
        state.pictures.append(Picture(url: source, alt: alt, width: nil))
        state.expectsAttributes = true
    }

    private mutating func write(html rawHTML: String, into state: inout InlineState) {
        switch MarkdownHTMLText.inline(rawHTML, links: &state.openHTMLLinks) {
        case .markdown(let text):
            state.expectsAttributes = false
            // `<kbd>⌘</kbd><kbd>K</kbd>` is two chips, and back to back they
            // would write ` `` ` — one run of two backticks, which is a fence
            // that then swallows both keys into a single span. A zero-width
            // space between them is invisible and keeps the runs apart.
            if text.hasPrefix("`"), state.text.hasSuffix("`") { state.text += "\u{200B}" }
            state.text += text
        case .image(let source, let alt, let width):
            write(image: source, alt: alt, into: &state)
            if let width, !state.pictures.isEmpty {
                state.pictures[state.pictures.count - 1].width = width
            }
        case .nothing:
            state.expectsAttributes = false
        }
    }

    /// `{: width=140 }` hung off the picture before this text, taken off the
    /// front of it. The leading colon is what marks an attribute list rather
    /// than a brace the author happened to type next.
    private func takingAttributes(from text: String, into state: inout InlineState) -> String {
        var index = text.startIndex
        while index < text.endIndex, text[index] == " " { index = text.index(after: index) }
        guard let open = text.index(index, offsetBy: 1, limitedBy: text.endIndex),
              open < text.endIndex, text[index] == "{", text[open] == ":",
              let close = text[open...].firstIndex(of: "}")
        else { return text }
        if let width = Self.width(in: text[text.index(after: open)..<close]), !state.pictures.isEmpty {
            state.pictures[state.pictures.count - 1].width = width
        }
        return String(text[text.index(after: close)...])
    }

    /// `width=140` out of an image's attribute list. Everything else in there —
    /// Bitbucket's `data-layout` — is somebody else's.
    private static func width(in attributes: Substring) -> CGFloat? {
        guard let key = attributes.range(of: "width=") else { return nil }
        let digits = attributes[key.upperBound...].prefix { $0.isNumber }
        guard let number = Int(digits), number > 0 else { return nil }
        return CGFloat(number)
    }
}

// MARK: - Writing a tick back

/// Ticking a box, which is the other half of a source range.
///
/// A checkbox has never been about drawing a toggle — the drawing was always
/// easy. It is about knowing *which* `[ ]` in the document to flip, and that is
/// what `MarkdownList.Item.line` says: the line the item was written on, in the
/// text exactly as it was handed to the parser. So the edit is made on the text
/// rather than on the blocks, and the document is parsed again from it, which is
/// what keeps the two from ever disagreeing.
enum MarkdownTask {
    /// The document with the box on `line` flipped, or nothing when that line
    /// no longer holds a box — the text having changed underneath, most likely.
    static func toggling(line: Int, to isDone: Bool, in text: String) -> String? {
        var lines = text.components(separatedBy: "\n")
        guard line >= 1, line <= lines.count, let flipped = flipping(lines[line - 1], to: isDone) else {
            return nil
        }
        lines[line - 1] = flipped
        return lines.joined(separator: "\n")
    }

    /// The first `[ ]`, `[x]` or `[X]` on the line, set to `isDone`. It is the
    /// first one that counts: the box belongs to the item's marker, and
    /// anything else in brackets comes after the words that follow it.
    private static func flipping(_ line: String, to isDone: Bool) -> String? {
        var index = line.startIndex
        while index < line.endIndex, let open = line[index...].firstIndex(of: "[") {
            let state = line.index(after: open)
            guard let close = line.index(open, offsetBy: 2, limitedBy: line.endIndex),
                  close < line.endIndex, line[close] == "]",
                  state < line.endIndex, line[state] == " " || line[state] == "x" || line[state] == "X"
            else {
                index = line.index(after: open)
                continue
            }
            var result = line
            result.replaceSubrange(state...state, with: isDone ? "x" : " ")
            return result
        }
        return nil
    }
}

// MARK: - HTML containers

/// The `<details>` and `<blockquote>` sections still open, and the blocks piling
/// up inside the innermost one.
///
/// This exists because a container's tags and its contents are *siblings* in the
/// tree rather than parent and child. Everything appended lands in the frame on
/// top; closing one folds it into the frame below as a block. A tag that is
/// never closed is closed by `finish()`, which is the reading a browser gives it
/// too.
private struct ContainerStack {
    private struct Frame {
        var container: MarkdownHTMLText.Container
        var summary = ""
        var blocks: [MarkdownText.Block] = []

        var block: MarkdownText.Block {
            switch container {
            case .details(let isOpen):
                // A section with no `<summary>` still needs something to click.
                .disclosure(summary: summary.isEmpty ? "Details" : summary, isOpen: isOpen, blocks: blocks)
            case .blockquote:
                .quote(nil, blocks)
            }
        }
    }

    private var root: [MarkdownText.Block] = []
    private var frames: [Frame] = []

    mutating func append(_ block: MarkdownText.Block) {
        if frames.isEmpty {
            root.append(block)
        } else {
            frames[frames.count - 1].blocks.append(block)
        }
    }

    mutating func open(_ container: MarkdownHTMLText.Container) {
        frames.append(Frame(container: container))
    }

    /// The summary belongs to the innermost `<details>` that has not been given
    /// one; a second `<summary>` in the same section is the reader's, not ours.
    mutating func setSummary(_ text: String) {
        guard let last = frames.indices.last, case .details = frames[last].container,
              frames[last].summary.isEmpty, !text.isEmpty
        else { return }
        frames[last].summary = text
    }

    /// Closes the innermost frame of the same kind, and anything left open
    /// inside it. A close tag with nothing open is a stray, and is ignored.
    mutating func close(_ container: MarkdownHTMLText.Container) {
        guard let index = frames.lastIndex(where: { $0.container.matches(container) }) else { return }
        while frames.count > index { closeTop() }
    }

    mutating func finish() -> [MarkdownText.Block] {
        while !frames.isEmpty { closeTop() }
        return root
    }

    private mutating func closeTop() {
        let frame = frames.removeLast()
        // An empty quote is a bar with nothing behind it; a section keeps its
        // summary even when the body is gone.
        if case .blockquote = frame.container, frame.blocks.isEmpty { return }
        append(frame.block)
    }
}
