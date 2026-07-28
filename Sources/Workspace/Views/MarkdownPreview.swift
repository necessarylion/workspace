import AppKit
import SwiftUI

/// Marks an inline `code` span. A run's own `backgroundColor` only ever paints a
/// square fill, so the rounded chip is drawn by `CodeChipRenderer`, which reads
/// this attribute back off the laid-out text.
///
/// It has to be carried by `Text.customAttribute` rather than set on the
/// `AttributedString`: a custom attribute put on the string does not survive
/// into the text layout, so the renderer never sees it.
@available(macOS 15.0, *)
private struct CodeChip: TextAttribute {}

/// Draws the rounded fills for a line of text and *nothing else* — this renders
/// the backdrop layer, and the glyphs are drawn by the selectable copy on top.
@available(macOS 15.0, *)
private struct CodeChipRenderer: TextRenderer {
    var color: Color
    var cornerRadius: CGFloat = 4

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        for line in layout {
            for rect in chipRects(in: line) {
                context.fill(
                    Path(roundedRect: rect, cornerRadius: cornerRadius),
                    with: .color(color)
                )
            }
        }
    }

    /// One rect per code span on the line. Touching runs are merged, so a span
    /// that the parser split in two still reads as a single chip; a span broken
    /// across lines gets one rounded chip per line, which is what we want.
    private func chipRects(in line: Text.Layout.Line) -> [CGRect] {
        var rects: [CGRect] = []
        for run in line where run[CodeChip.self] != nil {
            let rect = run.typographicBounds.rect
            if let last = rects.last, last.maxX >= rect.minX - 0.5 {
                rects[rects.count - 1] = last.union(rect)
            } else {
                rects.append(rect)
            }
        }
        return rects
    }
}

/// Puts a second, identical copy of the text behind the real one to paint the
/// chips.
///
/// SwiftUI ignores a `textRenderer` on text that is selectable, and the whole
/// preview is selectable, so the renderer cannot be attached to the text the
/// reader sees. The backdrop copy opts out of selection, so it keeps the
/// renderer — and being the same string at the same font and width, it lays out
/// line for line the same, which puts every chip exactly where its span is.
private struct CodeChipBackdrop: ViewModifier {
    let text: Text

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.background(alignment: .topLeading) {
                text
                    .textSelection(.disabled)
                    .textRenderer(CodeChipRenderer(color: MarkdownText.chipColor))
                    .accessibilityHidden(true)
                    .allowsHitTesting(false)
            }
        } else {
            // No `TextRenderer` before macOS 15; `inlineText` falls back to a
            // square fill there, so there is nothing to lay underneath.
            content
        }
    }
}

/// Full-page Markdown view for `.md` files: `MarkdownText` in a scroll view.
struct MarkdownPreview: View {
    let text: String

    var body: some View {
        ScrollView {
            MarkdownText(text: text)
                .frame(maxWidth: 720, alignment: .leading)
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .textSelection(.enabled)
    }
}

/// A light block-level Markdown renderer: headings, bullets, numbered lists,
/// task lists, quotes and fenced code blocks, with inline styling handled by
/// `AttributedString`. Does not scroll — embed it wherever text goes
/// (PR descriptions, comments, the file preview).
struct MarkdownText: View {
    private let source: Source

    /// Text the view parses itself, or blocks a container block already holds —
    /// a `<details>` section and a quote both draw their contents with a nested
    /// `MarkdownText`, and re-serialising them to Markdown to parse again would
    /// be work for nothing.
    private enum Source {
        case markdown(String)
        case parsed([Block])
    }

    init(text: String) { source = .markdown(text) }

    fileprivate init(blocks: [Block]) { source = .parsed(blocks) }

    /// Not private: `MarkdownPDF` writes the same document out to a file and
    /// walks this very list, so the page and the PDF cannot drift apart.
    ///
    /// `indirect` because a quote and a `<details>` section hold blocks of their
    /// own.
    indirect enum Block {
        case heading(level: Int, text: String)
        case paragraph(String)
        case bullet(indent: Int, text: String)
        case numbered(indent: Int, number: String, text: String)
        case task(done: Bool, text: String)
        case quote(Alert?, [Block])
        case disclosure(summary: String, isOpen: Bool, blocks: [Block])
        case code(language: String, text: String)
        case mermaid(String)
        case image(url: String, alt: String)
        case table(headers: [String], rows: [[String]])
        case rule
        case spacer
    }

    /// A GitHub alert — a quote whose first line is `[!WARNING]`. Both hosts
    /// write them and a bot writes little else, so a quote that is one is drawn
    /// with its name and colour rather than as an unexplained `[!WARNING]`.
    enum Alert: String {
        case note, tip, important, warning, caution

        init?(marker: String) {
            guard marker.hasPrefix("[!"), let end = marker.firstIndex(of: "]") else { return nil }
            let name = marker[marker.index(marker.startIndex, offsetBy: 2)..<end].lowercased()
            // Only when the marker is the whole line, the way the syntax reads.
            guard marker[marker.index(after: end)...].trimmingCharacters(in: .whitespaces).isEmpty,
                  let alert = Alert(rawValue: name)
            else { return nil }
            self = alert
        }

        var title: String { rawValue.capitalized }

        var symbol: String {
            switch self {
            case .note: "info.circle.fill"
            case .tip: "lightbulb.fill"
            case .important: "exclamationmark.bubble.fill"
            case .warning: "exclamationmark.triangle.fill"
            case .caution: "exclamationmark.octagon.fill"
            }
        }

        var color: Color {
            switch self {
            case .note: .blue
            case .tip: .green
            case .important: .purple
            case .warning: .orange
            case .caution: .red
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func view(for block: Block) -> some View {
        switch block {
        case .heading(let level, let text):
            Self.inline(text, baseSize: headingSize(level))
                .font(headingFont(level))
                .padding(.top, level <= 2 ? 8 : 4)
        case .paragraph(let text):
            Self.inline(text)
        case .bullet(let indent, let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(indent > 0 ? "◦" : "•").foregroundStyle(.secondary)
                Self.inline(text)
            }
            .padding(.leading, CGFloat(indent) * 16)
        case .numbered(let indent, let number, let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(number).")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Self.inline(text)
            }
            .padding(.leading, CGFloat(indent) * 16)
        case .task(let done, let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: done ? "checkmark.square.fill" : "square")
                    .foregroundStyle(done ? Color.green : Color.secondary)
                    .imageScale(.small)
                // No strikethrough on a ticked item: the box already says it is
                // done, and struck-through text is the harder to read the more
                // there is of it.
                Self.inline(text)
                    .foregroundStyle(done ? .secondary : .primary)
            }
        case .quote(let alert, let blocks):
            HStack(alignment: .top, spacing: 10) {
                Rectangle()
                    .fill(alert.map { AnyShapeStyle($0.color.opacity(0.7)) } ?? AnyShapeStyle(.quaternary))
                    .frame(width: 3)
                VStack(alignment: .leading, spacing: 6) {
                    if let alert {
                        Label(alert.title, systemImage: alert.symbol)
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(alert.color)
                    }
                    // An alert is the point of the comment it sits in, so it
                    // keeps the body colour; a plain quote is someone else's
                    // words and stays back.
                    MarkdownText(blocks: blocks)
                        .foregroundStyle(alert == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                }
            }
        case .disclosure(let summary, let isOpen, let blocks):
            MarkdownDisclosure(summary: summary, isOpen: isOpen, blocks: blocks)
        case .code(let language, let code):
            ScrollView(.horizontal) {
                // Coloured by the editor's own tree-sitter setup when the fence
                // names a language we have a grammar for, plain when it does not.
                codeText(code, language: language)
                    .font(.system(.callout, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
            // The fill alone is faint against a dark viewer; the outline is
            // what actually marks where the block starts and stops.
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary, lineWidth: 1))
        case .mermaid(let source):
            MermaidDiagram(source: source)
                .padding(.vertical, 4)
        case .image(let address, let alt):
            // A picture is only drawn for an address the app could actually
            // fetch; a relative one in a comment points into a repository
            // checkout the viewer has no idea about, so it stays as its text.
            if let url = URL(string: address), url.scheme == "http" || url.scheme == "https" {
                MarkdownImage(url: url, alt: alt)
                    .padding(.vertical, 2)
            } else {
                Self.inline(alt.isEmpty ? address : alt)
                    .foregroundStyle(.secondary)
            }
        case .table(let headers, let rows):
            // No horizontal scroll view around this: one would offer the table
            // unbounded width, so a cell would never wrap and a wide table would
            // scroll instead of fitting. Bounded by the pane, the columns take
            // what their text asks for and long cells wrap — see
            // `MarkdownTableLayout` for why this is not a `Grid`.
            MarkdownTableLayout(columns: headers.count) {
                // The fill goes on each cell, not on a row: a row background
                // only covers the cells' own widths, which leaves unpainted
                // gaps wherever a column is wider than its text.
                // `maxWidth: .infinity` makes a cell take the whole column.
                ForEach(headers.indices, id: \.self) { column in
                    Self.inline(headers[column])
                        .font(.callout.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(maxHeight: .infinity, alignment: .topLeading)
                        .background(.quaternary.opacity(0.4))
                }
                ForEach(rows.indices, id: \.self) { index in
                    ForEach(headers.indices, id: \.self) { column in
                        Self.inline(column < rows[index].count ? rows[index][column] : "")
                            // Take as many lines as the wrapped text needs
                            // rather than being squeezed onto one.
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            // Once cells wrap they no longer agree on a
                            // height, and a fill that stops at the text
                            // leaves the stripe ragged. Stretch every cell
                            // to the tallest one in its row.
                            .frame(maxHeight: .infinity, alignment: .topLeading)
                            .background(
                                index.isMultiple(of: 2)
                                    ? AnyShapeStyle(.clear)
                                    : AnyShapeStyle(.quaternary.opacity(0.15))
                            )
                            // The layout owns no spacing, so the rule between
                            // rows rides on the cells; each one spans its own
                            // column and together they draw a single line.
                            .overlay(alignment: .top) { Divider() }
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .background(.quaternary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary, lineWidth: 1))
        case .rule:
            Divider()
        case .spacer:
            Spacer().frame(height: 2)
        }
    }

    private func codeText(_ code: String, language: String) -> Text {
        guard let highlighted = MarkdownCodeHighlighter.highlight(code, language: language) else {
            return Text(code)
        }
        return Text(highlighted)
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .system(.title, weight: .bold)
        case 2: .system(.title2, weight: .semibold)
        case 3: .system(.title3, weight: .semibold)
        default: .system(.headline)
        }
    }

    /// One line of styled text, with the chip backdrop layered behind it.
    fileprivate static func inline(_ source: String, baseSize: CGFloat = MarkdownText.bodySize) -> some View {
        let text = inlineText(source, baseSize: baseSize)
        // Both layers are the same `Text`, and `.font`/`.foregroundStyle` set by
        // the caller reach the backdrop through the environment, so the two
        // always agree on how the text is laid out.
        return text.modifier(CodeChipBackdrop(text: text))
    }

    /// `baseSize` is the point size of the block the text sits in, so a code
    /// span can be set one point below whatever surrounds it — including inside
    /// a heading, where the run would otherwise be left at body size.
    /// Returns a `Text` rather than an `AttributedString` because the chip
    /// attribute can only be attached per `Text`. Concatenating with `+` still
    /// leaves one `Text`, so the whole thing wraps as a single paragraph.
    private static func inlineText(_ source: String, baseSize: CGFloat) -> Text {
        let parsed = (try? AttributedString(
            markdown: source,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(source)

        // SwiftUI renders `inline code` monospaced but paints nothing behind
        // it, so in a wall of prose it barely reads as code.
        var result = Text(verbatim: "")
        for run in parsed.runs {
            var piece = AttributedString(parsed[run.range])
            guard run.inlinePresentationIntent?.contains(.code) == true else {
                result = result + Text(piece)
                continue
            }
            // The fill cannot be inset, so the breathing room at each end has
            // to be real text: a narrow no-break space, styled like the code so
            // the fill covers it and no line break can land between the padding
            // and the code.
            var pad = AttributedString("\u{202F}")
            pad.mergeAttributes(run.attributes)
            piece = pad + piece + pad
            // A point down from its surroundings: monospaced letters and digits
            // run wide, so at a matching size code looks larger than the prose
            // it is quoted in.
            piece.font = .system(size: baseSize - 1, design: .monospaced)
            // Green on the chip, the way a terminal renders a code span: the
            // fill alone is subtle enough that a short span can be missed.
            piece.foregroundColor = Self.chipTextColor
            if #available(macOS 15.0, *) {
                // Tagged only; `CodeChipBackdrop` paints the rounded fill.
                result = result + Text(piece).customAttribute(CodeChip())
            } else {
                // No `TextRenderer` before macOS 15, so the chip stays square.
                piece.backgroundColor = Self.chipColor
                result = result + Text(piece)
            }
        }
        return result
    }

    static let chipColor = Color.secondary.opacity(0.22)

    /// The colour of the code itself. Hard-coded rather than taken from the
    /// syntax palette: a code span has no language and so no capture to look
    /// up, and the palette's `string` colour — the obvious stand-in — is red in
    /// most light themes, which reads as an error. Two shades of green instead,
    /// dark enough to stay legible on paper-white and light enough on the dark
    /// chip.
    static let chipTextColor = Color(nsColor: NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return isDark
            ? NSColor(srgbRed: 0.60, green: 0.80, blue: 0.51, alpha: 1)
            : NSColor(srgbRed: 0.10, green: 0.45, blue: 0.20, alpha: 1)
    })

    /// The point size SwiftUI's default body font resolves to, which every
    /// block but a heading is set in.
    static let bodySize = NSFont.preferredFont(forTextStyle: .body).pointSize

    /// The point size of `headingFont(level)`, for sizing code inside a heading.
    private func headingSize(_ level: Int) -> CGFloat {
        let style: NSFont.TextStyle = switch level {
        case 1: .title1
        case 2: .title2
        case 3: .title3
        default: .headline
        }
        return NSFont.preferredFont(forTextStyle: style).pointSize
    }

    @MainActor
    private var blocks: [Block] {
        switch source {
        case .markdown(let text): Self.cachedBlocks(in: text)
        case .parsed(let blocks): blocks
        }
    }

    /// The parse, remembered.
    ///
    /// A view body runs many times over for text that has not changed — a
    /// scroll, a hover, a window resize — and a page of PR comments is a stack
    /// of these. Parsing the same Markdown on each of those passes is work
    /// nobody sees, so the answer is kept, the way `MarkdownCodeHighlighter`
    /// keeps its colours. The cap only stops a long reading session from
    /// growing this without end.
    @MainActor
    private static func cachedBlocks(in text: String) -> [Block] {
        if let cached = cache[text] { return cached }
        let parsed = blocks(in: text)
        if cache.count > 200 { cache.removeAll() }
        cache[text] = parsed
        return parsed
    }

    @MainActor
    private static var cache: [String: [Block]] = [:]

    static func blocks(in text: String) -> [Block] {
        // The bookkeeping a bot hides in `<!-- … -->` goes first, so nothing
        // downstream has to know it was ever there.
        parse(MarkdownHTMLText.strippingComments(text), depth: 0)
    }

    /// True when `blocks` — or anything nested in them — holds a diagram.
    /// `MarkdownPDF` asks before copying mermaid in beside the page.
    static func containsDiagram(_ blocks: [Block]) -> Bool {
        blocks.contains { block in
            switch block {
            case .mermaid: true
            case .quote(_, let nested), .disclosure(_, _, let nested): containsDiagram(nested)
            default: false
            }
        }
    }

    /// Peels off the `<details>` and `<blockquote>` sections, outermost first,
    /// and hands what is between them to the line parser. A section's own
    /// contents come back through here, which is what lets a review nested four
    /// deep read as four foldable sections rather than as its tags.
    ///
    /// `depth` is only a backstop against text that nests without end; real
    /// output from a bot bottoms out around five.
    private static func parse(_ text: String, depth: Int) -> [Block] {
        guard depth < 12, let container = MarkdownHTMLText.container(in: text) else {
            return tidied(plainBlocks(in: text, depth: depth))
        }
        var result = plainBlocks(in: String(container.before), depth: depth)

        switch container.tag {
        case .details:
            let split = MarkdownHTMLText.summary(in: container.inner)
            let summary = MarkdownHTMLText.markdown(from: split?.summary ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            result.append(.disclosure(
                // A section with no `<summary>` still needs something to click.
                summary: summary.isEmpty ? "Details" : summary,
                isOpen: container.isOpen,
                blocks: parse(split?.body ?? String(container.inner), depth: depth + 1)
            ))
        case .blockquote:
            result.append(.quote(nil, parse(String(container.inner), depth: depth + 1)))
        }

        result += parse(String(container.after), depth: depth)
        return tidied(result)
    }

    /// A run of blank lines is one paragraph break, and the blank lines a
    /// section opens and closes with are nothing at all — the stack's own
    /// spacing is what holds the blocks apart.
    ///
    /// This matters here in a way it does not in a hand-written document: HTML
    /// needs a blank line either side of a tag for the Markdown inside it to be
    /// read as Markdown, so a bot writing `<details>` sections leaves two or
    /// three, and each one used to push the next section further down.
    private static func tidied(_ blocks: [Block]) -> [Block] {
        var result: [Block] = []
        for block in blocks {
            guard case .spacer = block else {
                result.append(block)
                continue
            }
            if let last = result.last, case .spacer = last { continue }
            if result.isEmpty { continue }
            result.append(block)
        }
        if let last = result.last, case .spacer = last { result.removeLast() }
        return result
    }

    private static func plainBlocks(in text: String, depth: Int) -> [Block] {
        var result: [Block] = []
        var codeBuffer: [String] = []
        var inCode = false
        /// The word after the opening ``` — "swift", "mermaid", or nothing.
        var codeLanguage = ""
        var tableBuffer: [[String]] = []
        var quoteBuffer: [String] = []

        /// A quote is parsed as a document of its own rather than line by line:
        /// it can hold anything, a `<details>` section included, and a bot's
        /// alert is several paragraphs behind one bar.
        func flushQuote() {
            guard !quoteBuffer.isEmpty else { return }
            var lines = quoteBuffer
            quoteBuffer.removeAll()
            var alert: Alert?
            if let first = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
               let marked = Alert(marker: lines[first].trimmingCharacters(in: .whitespaces)) {
                alert = marked
                lines.remove(at: first)
            }
            result.append(.quote(alert, parse(lines.joined(separator: "\n"), depth: depth + 1)))
        }

        /// A fence is a diagram when it says so and has something in it;
        /// everything else stays a code block.
        func flushCode() {
            let body = codeBuffer.joined(separator: "\n")
            let language = codeLanguage
            codeBuffer.removeAll()
            codeLanguage = ""
            let hasContent = !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if language.lowercased() == "mermaid", hasContent {
                result.append(.mermaid(body))
            } else {
                result.append(.code(language: language, text: body))
            }
        }

        func flushTable() {
            guard !tableBuffer.isEmpty else { return }
            defer { tableBuffer.removeAll() }
            // A lone |…| line is not a table, just a paragraph with pipes.
            guard tableBuffer.count >= 2 else {
                result.append(.paragraph(tableBuffer[0].joined(separator: " | ")))
                return
            }
            let headers = tableBuffer[0]
            var rows = Array(tableBuffer.dropFirst())
            // Drop the |---|---| separator row if present.
            if let first = rows.first, first.allSatisfy({ cell in
                !cell.isEmpty && cell.allSatisfy { "-: ".contains($0) }
            }) {
                rows.removeFirst()
            }
            // Pad short rows so every GridRow has the same number of cells.
            rows = rows.map { row in
                row + Array(repeating: "", count: max(0, headers.count - row.count))
            }
            result.append(.table(headers: headers, rows: rows))
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            // Whatever HTML the line still carries becomes the Markdown that
            // says the same thing, so everything below reads one syntax.
            var line = inCode ? String(rawLine) : MarkdownHTMLText.markdown(from: String(rawLine))
            var trimmed = line.trimmingCharacters(in: .whitespaces)

            // The quote comes off before the pictures are pulled out: its lines
            // are re-parsed as a document, and one that went through here first
            // would have its pictures hoisted out of the quote and left after it.
            if !inCode, trimmed.hasPrefix(">") {
                flushTable()
                var rest = Substring(trimmed).dropFirst()
                if rest.hasPrefix(" ") { rest = rest.dropFirst() }
                quoteBuffer.append(String(rest))
                continue
            }
            flushQuote()

            // Pictures come out of the line before anything else looks at it, so
            // an image sitting on a bullet or at the end of a sentence still
            // becomes a picture and the words around it still read as words.
            // `AttributedString` would otherwise swallow the whole `![…](…)`
            // and draw nothing at all.
            var images: [(url: String, alt: String)] = []
            if !inCode, line.contains("![") {
                let split = splitImages(from: line)
                line = split.text
                trimmed = line.trimmingCharacters(in: .whitespaces)
                images = split.images
            }
            defer {
                for image in images {
                    result.append(.image(url: image.url, alt: image.alt))
                }
            }
            // A line that was nothing but pictures leaves no text behind, and an
            // empty line here would only add a gap above them.
            let isImageOnly = !images.isEmpty && trimmed.isEmpty

            if !inCode, trimmed.hasPrefix("|"), trimmed.dropFirst().contains("|") {
                tableBuffer.append(tableCells(trimmed))
                continue
            }
            flushTable()

            if trimmed.hasPrefix("```") {
                if inCode {
                    flushCode()
                } else {
                    codeLanguage = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                }
                inCode.toggle()
                continue
            }

            if inCode {
                codeBuffer.append(line)
                continue
            }

            // Two spaces (or one tab) of leading indentation = one list level.
            let leading = line.prefix { $0 == " " || $0 == "\t" }
            let indent = leading.reduce(0) { $0 + ($1 == "\t" ? 2 : 1) } / 2

            if isImageOnly {
                // The pictures are all this line had; `defer` appends them.
            } else if trimmed.isEmpty {
                result.append(.spacer)
            } else if trimmed == "---" || trimmed == "***" {
                result.append(.rule)
            } else if trimmed.hasPrefix("#") {
                let level = trimmed.prefix(while: { $0 == "#" }).count
                let title = trimmed.dropFirst(level).trimmingCharacters(in: .whitespaces)
                result.append(.heading(level: min(level, 6), text: title))
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
                let rest = String(trimmed.dropFirst(2))
                // Trimmed: a bot writes its checkbox id in a comment between the
                // box and the label, and taking the comment out leaves the gap.
                if rest.hasPrefix("[ ] ") {
                    result.append(.task(done: false, text: rest.dropFirst(4).trimmingCharacters(in: .whitespaces)))
                } else if rest.hasPrefix("[x] ") || rest.hasPrefix("[X] ") {
                    result.append(.task(done: true, text: rest.dropFirst(4).trimmingCharacters(in: .whitespaces)))
                } else {
                    result.append(.bullet(indent: indent, text: rest))
                }
            } else if let ordered = orderedItem(trimmed) {
                result.append(.numbered(indent: indent, number: ordered.number, text: ordered.text))
            } else {
                result.append(.paragraph(trimmed))
            }
        }

        flushQuote()
        flushTable()
        // An unterminated fence — the file is still being typed, most likely.
        if inCode, !codeBuffer.isEmpty {
            flushCode()
        }
        return result
    }

    /// Pulls every `![alt](url)` out of one line, handing back what is left of
    /// the line and the pictures in the order they appeared.
    ///
    /// Bitbucket writes an attribute list after the image —
    /// `![](…png){: data-layout='center' }` — which is not Markdown any parser
    /// here knows; it is swallowed along with the image rather than left behind
    /// as stray braces in the middle of a sentence.
    private static func splitImages(from line: String) -> (text: String, images: [(url: String, alt: String)]) {
        var text = ""
        var images: [(url: String, alt: String)] = []
        var index = line.startIndex

        while index < line.endIndex {
            guard line[index] == "!",
                  let bracket = line.index(index, offsetBy: 1, limitedBy: line.endIndex),
                  bracket < line.endIndex, line[bracket] == "[",
                  let altEnd = line[bracket...].firstIndex(of: "]"),
                  let open = line.index(altEnd, offsetBy: 1, limitedBy: line.endIndex),
                  open < line.endIndex, line[open] == "(",
                  // A closing paren inside the address would end it early, but
                  // an address with one in it is rare enough not to trade the
                  // simplicity for.
                  let close = line[open...].firstIndex(of: ")")
            else {
                text.append(line[index])
                index = line.index(after: index)
                continue
            }

            let alt = String(line[line.index(after: bracket)..<altEnd])
            let address = String(line[line.index(after: open)..<close])
                .trimmingCharacters(in: .whitespaces)
            images.append((url: address, alt: alt.trimmingCharacters(in: .whitespaces)))
            index = line.index(after: close)

            // The `{: … }` Bitbucket hangs off the end, when there is one. The
            // leading colon is what marks it as an attribute list rather than a
            // brace the author happened to type next.
            var attributes = index
            while attributes < line.endIndex, line[attributes] == " " {
                attributes = line.index(after: attributes)
            }
            if attributes < line.endIndex, line[attributes] == "{",
               let colon = line.index(attributes, offsetBy: 1, limitedBy: line.endIndex),
               colon < line.endIndex, line[colon] == ":",
               let end = line[colon...].firstIndex(of: "}") {
                index = line.index(after: end)
            }
        }

        return (text, images)
    }

    /// "| a | b |" → ["a", "b"].
    private static func tableCells(_ line: String) -> [String] {
        var inner = Substring(line)
        if inner.hasPrefix("|") { inner = inner.dropFirst() }
        if inner.hasSuffix("|") { inner = inner.dropLast() }
        return inner
            .split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// "3. text" or "3) text" → ("3", "text"); nil when not an ordered item.
    private static func orderedItem(_ line: String) -> (number: String, text: String)? {
        let digits = line.prefix(while: \.isNumber)
        guard !digits.isEmpty, digits.count <= 4 else { return nil }
        let rest = line.dropFirst(digits.count)
        guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
        return (String(digits), rest.dropFirst(2).trimmingCharacters(in: .whitespaces))
    }
}

/// A `<details>` section: its summary on a row that folds the rest away.
///
/// Not a `DisclosureGroup`. The contents are selectable text, and the label
/// would be too — a drag across the summary would select rather than open it.
/// A button of its own keeps the whole row a click target, and the summary opts
/// out of selection so nothing swallows the click.
private struct MarkdownDisclosure: View {
    let summary: String
    let blocks: [MarkdownText.Block]
    @State private var isExpanded: Bool

    init(summary: String, isOpen: Bool, blocks: [MarkdownText.Block]) {
        self.summary = summary
        self.blocks = blocks
        _isExpanded = State(initialValue: isOpen)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        // The triangle turns about its own middle, which sits a
                        // little above the baseline the row is aligned on.
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] }
                    MarkdownText.inline(summary)
                        .fontWeight(.semibold)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .textSelection(.disabled)

            if isExpanded {
                MarkdownText(blocks: blocks)
                    .padding(.leading, 14)
            }
        }
    }
}

/// Lays a Markdown table out one column at a time.
///
/// `Grid` cannot do this: it hands every column the same share of the pane, so a
/// `#` column holding `B1` ends up as wide as the one holding a sentence, and
/// the sentence wraps for no reason. Here each column asks for the width its
/// longest cell wants on one line, and only the columns that ask for more than
/// their fair share give any of it back — a narrow column stays narrow and the
/// width it does not need goes to the ones that have to wrap.
///
/// Subviews arrive in row-major order, `columns` per row, the header first.
private struct MarkdownTableLayout: Layout {
    let columns: Int

    struct Cache {
        /// Width each column wants with nothing wrapped.
        var natural: [CGFloat]
        /// Width below which a column's longest word would be cut.
        var minimum: [CGFloat]
        /// The width the rest of the cache was resolved for; `nil` until then.
        var resolvedFor: CGFloat?
        var widths: [CGFloat] = []
        var rowHeights: [CGFloat] = []
    }

    func makeCache(subviews: Subviews) -> Cache {
        var natural = [CGFloat](repeating: 0, count: max(columns, 1))
        var minimum = natural
        for (index, subview) in subviews.enumerated() {
            let column = index % max(columns, 1)
            natural[column] = max(natural[column], subview.sizeThatFits(.unspecified).width)
            // The narrowest proposal there is: a `Text` answers it with the
            // width of its longest unbreakable run.
            minimum[column] = max(
                minimum[column],
                subview.sizeThatFits(ProposedViewSize(width: 0, height: nil)).width
            )
        }
        return Cache(natural: natural, minimum: zip(minimum, natural).map { Swift.min($0, $1) })
    }

    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        cache = makeCache(subviews: subviews)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let width = proposal.width ?? cache.natural.reduce(0, +)
        resolve(width: width, subviews: subviews, cache: &cache)
        // The columns, not the proposal: asked for nothing the table still
        // answers with the width its longest words need.
        return CGSize(
            width: cache.widths.reduce(0, +),
            height: cache.rowHeights.reduce(0, +)
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache
    ) {
        resolve(width: bounds.width, subviews: subviews, cache: &cache)
        var y = bounds.minY
        for row in cache.rowHeights.indices {
            var x = bounds.minX
            for column in 0..<columns {
                let index = row * columns + column
                guard index < subviews.count else { break }
                subviews[index].place(
                    at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(
                        width: cache.widths[column],
                        height: cache.rowHeights[row]
                    )
                )
                x += cache.widths[column]
            }
            y += cache.rowHeights[row]
        }
    }

    /// Fills in the column widths and row heights for `width`. Measuring rows is
    /// the expensive half, so a repeat of the same width reuses the last answer.
    private func resolve(width: CGFloat, subviews: Subviews, cache: inout Cache) {
        guard columns > 0, !subviews.isEmpty else {
            cache.widths = []
            cache.rowHeights = []
            return
        }
        guard cache.resolvedFor != width else { return }
        cache.resolvedFor = width
        cache.widths = Self.columnWidths(
            natural: cache.natural,
            minimum: cache.minimum,
            available: width
        )
        // A row is as tall as the cell that wraps onto the most lines.
        let rows = (subviews.count + columns - 1) / columns
        cache.rowHeights = (0..<rows).map { row in
            (0..<columns).reduce(CGFloat.zero) { height, column in
                let index = row * columns + column
                guard index < subviews.count else { return height }
                let cell = subviews[index].sizeThatFits(
                    ProposedViewSize(width: cache.widths[column], height: nil)
                )
                return max(height, cell.height)
            }
        }
    }

    /// Splits `available` between the columns: anything that fits in an equal
    /// share is left at the width it asked for, and what is left over goes to
    /// the wide columns in proportion to how much they wanted.
    static func columnWidths(
        natural: [CGFloat],
        minimum: [CGFloat],
        available: CGFloat
    ) -> [CGFloat] {
        guard !natural.isEmpty else { return [] }
        let wanted = natural.reduce(0, +)
        guard wanted > 0 else {
            return natural.map { _ in available / CGFloat(natural.count) }
        }
        // Room to spare: the table still spans the pane, but the extra is shared
        // out in proportion, so a narrow column stays narrow.
        if wanted <= available {
            return natural.map { $0 + (available - wanted) * ($0 / wanted) }
        }

        var widths = natural
        var flexible = Set(natural.indices)
        var budget = available
        // Pin every column that is content with an equal share. Each pass frees
        // up more for the rest, which can settle a further column, so repeat
        // until a pass pins nothing.
        var settled = false
        while !settled, !flexible.isEmpty {
            settled = true
            let share = budget / CGFloat(flexible.count)
            for column in flexible.sorted() where natural[column] <= share {
                widths[column] = natural[column]
                budget -= natural[column]
                flexible.remove(column)
                settled = false
            }
        }
        // The rest wrap. They divide what is left in proportion to what they
        // asked for, but never down past their longest word.
        let asked = flexible.reduce(CGFloat.zero) { $0 + natural[$1] }
        for column in flexible where asked > 0 {
            widths[column] = max(minimum[column], budget * natural[column] / asked)
        }
        return widths
    }
}
