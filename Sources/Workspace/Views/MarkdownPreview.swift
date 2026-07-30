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
    /// Nothing when the line has no code span in it, which is most lines: then
    /// there is no second copy to lay out, and nothing to draw behind.
    let text: Text?

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *), let text {
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

/// A cache that forgets in halves rather than all at once.
///
/// The obvious cap — empty the whole thing once it grows past a limit — throws
/// away what is on screen along with what is not, and the pass that overflowed
/// it is usually the pass that then has to make all of it again: a pull request
/// with three hundred comments does exactly that. Keeping the generation before
/// the current one means anything still being read is at worst one lookup away,
/// and finding it there moves it forward, so what is on screen settles into the
/// live half and what has been scrolled past falls out of the old one.
private struct GenerationCache<Key: Hashable, Value> {
    /// How much is held before the live half is set aside. Twice this is the
    /// most that is ever kept.
    let limit: Int

    private var live: [Key: Value] = [:]
    private var previous: [Key: Value] = [:]

    init(limit: Int) { self.limit = limit }

    mutating func value(for key: Key) -> Value? {
        if let value = live[key] { return value }
        guard let value = previous[key] else { return nil }
        // A promotion fills the live half exactly as an insert does, and a pass
        // that finds everything it wants in the old half is all promotions: this
        // has to count against the cap too, or the two halves grow past it.
        rotateIfFull()
        live[key] = value
        return value
    }

    mutating func insert(_ value: Value, for key: Key) {
        rotateIfFull()
        live[key] = value
    }

    /// Sets the live half aside once it is full, which is the only thing that
    /// ever drops anything: what was in the old half at that moment is gone.
    private mutating func rotateIfFull() {
        guard live.count >= limit else { return }
        previous = live
        live = [:]
    }
}

/// Full-page Markdown view for `.md` files: `MarkdownText` in a scroll view,
/// with the two things a whole document wants that a comment does not — an
/// outline to jump around a long one by, and checkboxes that write back.
struct MarkdownPreview: View {
    let text: String
    /// The file the text was read from, when it was read from one. A README
    /// writes its pictures as paths beside itself — `![](assets/preview.jpeg)` —
    /// and this is what those are paths from.
    var baseURL: URL?
    /// The repository the file belongs to, so a `#123` in it is that
    /// repository's pull request.
    var links: MarkdownLinks = .none
    /// Ticking a box, given the 1-based line and the state it should end in.
    var onToggleTask: MarkdownTaskToggle?

    var body: some View {
        ScrollViewReader { scroll in
            ScrollView {
                MarkdownText(text: text, relativeTo: baseURL, anchorsHeadings: true)
                    .environment(\.markdownLinks, links)
                    .environment(\.markdownTaskToggle, onToggleTask)
                    .frame(maxWidth: 720, alignment: .leading)
                    .padding(28)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .overlay(alignment: .topTrailing) {
                MarkdownOutlineButton(headings: headings) { index in
                    withAnimation(ViewerMotion.isReduced ? nil : .easeInOut(duration: 0.2)) {
                        scroll.scrollTo(MarkdownText.headingID(index), anchor: .top)
                    }
                }
                .padding(12)
            }
        }
        .textSelection(.enabled)
    }

    /// Read off the very blocks the body draws, so the outline costs a cache
    /// lookup rather than a second parse of the document.
    private var headings: [(index: Int, level: Int, title: String)] {
        MarkdownText.outline(
            of: MarkdownText.cachedBlocks(in: text, relativeTo: baseURL, links: links)
        )
    }
}

/// The outline, behind a button in the corner of the page.
///
/// A popover rather than a sidebar: a `.md` file is read in the same pane as
/// every other file, and a permanent column of headings would take width from
/// the words on a document that mostly does not need one. It is not offered at
/// all for a document with nothing to jump between.
private struct MarkdownOutlineButton: View {
    let headings: [(index: Int, level: Int, title: String)]
    let onSelect: (Int) -> Void

    @State private var isShowing = false

    var body: some View {
        if headings.count >= 3 {
            Button { isShowing.toggle() } label: {
                Image(systemName: "list.bullet.indent")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(6)
                    .background(.background.opacity(0.85), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help("Outline")
            .popover(isPresented: $isShowing, arrowEdge: .bottom) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(headings, id: \.index) { heading in
                            Button {
                                isShowing = false
                                onSelect(heading.index)
                            } label: {
                                Text(heading.title)
                                    .font(heading.level <= 1 ? .callout.weight(.semibold) : .callout)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    // A level is a step in, so the shape of the
                                    // document is readable in the list itself.
                                    .padding(.leading, CGFloat(max(0, heading.level - 1)) * 12)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .pointerCursor()
                        }
                    }
                    .padding(10)
                }
                .frame(width: 260, height: min(CGFloat(headings.count) * 22 + 20, 420))
            }
        }
    }
}

/// One list, bulleted or numbered, with every item holding blocks of its own.
struct MarkdownList {
    var isOrdered: Bool
    /// What `1.` was written as — an `OrderedList` may start at any number.
    var start: Int
    var items: [Item]

    struct Item {
        /// Nothing for an ordinary item, `false` for `[ ]`, `true` for `[x]`.
        var isDone: Bool?
        /// The 1-based line the item was written on, which is where a tick is
        /// written back to. Nothing for an item that came out of HTML, where
        /// there is no source line to speak of.
        var line: Int?
        var blocks: [MarkdownText.Block]
    }
}

/// How a table column was asked to line up — the `|:---:|` row the old parser
/// dropped on the floor.
enum MarkdownColumn {
    case leading, center, trailing

    var textAlignment: TextAlignment {
        switch self {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    var frameAlignment: Alignment {
        switch self {
        case .leading: .topLeading
        case .center: .top
        case .trailing: .topTrailing
        }
    }
}

/// A block-level Markdown renderer: headings, lists, task lists, quotes, tables
/// and fenced code blocks, with inline styling handled by `AttributedString`.
/// Does not scroll — embed it wherever text goes (PR descriptions, comments,
/// the file preview).
///
/// The document is read by `MarkdownParser`; everything here draws what it says.
struct MarkdownText: View {
    private let source: Source
    /// Where a `#123` and an `@name` in this document point. It travels in the
    /// environment because a pull request draws Markdown in a dozen places —
    /// the description, every comment, every reply nested under one — and they
    /// all belong to the same repository. Setting it once at the page is the
    /// whole of it.
    @Environment(\.markdownLinks) private var links
    /// How deep in a list this text sits, so a sub-bullet is drawn as one.
    /// Whether the headings in this text answer to a name the outline can scroll
    /// to. Only the whole-document preview asks for it: a pull request draws a
    /// dozen of these on one page, and naming a block in every one of them would
    /// put the same name on a dozen different views.
    private let anchorsHeadings: Bool

    /// Text the view parses itself, or blocks a container block already holds —
    /// a `<details>` section and a quote both draw their contents with a nested
    /// `MarkdownText`, and re-serialising them to Markdown to parse again would
    /// be work for nothing.
    private enum Source {
        case markdown(String, base: URL?)
        case parsed([Block])
    }

    /// `baseURL` is the file the Markdown came from, and only a file on disk has
    /// one: it is what a picture written as a relative path is a path from. A PR
    /// description or a comment has no folder, so it passes nothing.
    init(text: String, relativeTo baseURL: URL? = nil, anchorsHeadings: Bool = false) {
        source = .markdown(text, base: baseURL)
        self.anchorsHeadings = anchorsHeadings
    }

    fileprivate init(blocks: [Block]) {
        source = .parsed(blocks)
        anchorsHeadings = false
    }

    /// Not private: `MarkdownPDF` writes the same document out to a file and
    /// walks this very list, so the page and the PDF cannot drift apart.
    ///
    /// `indirect` because a quote, a `<details>` section and a list item all
    /// hold blocks of their own.
    indirect enum Block {
        case heading(level: Int, text: String)
        case paragraph(String)
        /// One list, with its items nested inside it rather than flattened into
        /// rows carrying an `indent:`. A sub-list, a second paragraph under a
        /// bullet and a fence inside an item are all just blocks of the item —
        /// which is what cmark says they are.
        case list(MarkdownList)
        case quote(Alert?, [Block])
        case disclosure(summary: String, isOpen: Bool, blocks: [Block])
        case code(language: String, text: String)
        case mermaid(String)
        /// `width` is the one an HTML `<img width="140">` asked for, in points.
        /// Markdown's own `![](…)` cannot say it, so it is usually nothing and
        /// the picture is drawn at its own size.
        case image(url: String, alt: String, width: CGFloat?)
        case table(headers: [String], rows: [[String]], alignments: [MarkdownColumn])
        case rule
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
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                view(for: block)
                    // A name only where something needs to find it. Naming
                    // every block was a real cost: an explicit `.id` is
                    // structural identity, so a page of comments carried
                    // hundreds of them — the same handful of names over and
                    // over — and SwiftUI tore views down and built them again
                    // as the indices moved under it.
                    .modifier(HeadingAnchor(id: anchorName(for: block, at: index)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    private func anchorName(for block: Block, at index: Int) -> String? {
        guard anchorsHeadings, case .heading = block else { return nil }
        return Self.headingID(index)
    }

    /// What a heading answers to, so the outline can scroll to it.
    static func headingID(_ index: Int) -> String { "markdown-heading-\(index)" }

    @ViewBuilder
    private func view(for block: Block) -> some View {
        switch block {
        case .heading(let level, let text):
            Self.inline(text, baseSize: headingSize(level))
                .font(headingFont(level))
                .padding(.top, level <= 2 ? 8 : 4)
        case .paragraph(let text):
            Self.inline(text)
        case .list(let list):
            // The depth and the toggle are read by the list itself, not here:
            // reading an environment value is a dependency on it, and every
            // paragraph of every comment would otherwise be rebuilt whenever
            // either of them changed.
            MarkdownListView(list: list)
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
            MarkdownCodeBlock(code: code, text: codeText(code, language: language))
        case .mermaid(let source):
            MermaidDiagram(source: source)
                .padding(.vertical, 4)
        case .image(let address, let alt, let width):
            // A picture is only drawn for an address the app could actually
            // reach: one it can fetch, or a file `blocks(in:relativeTo:)` found
            // beside the document. A relative one in a comment points into a
            // repository checkout the viewer has no idea about — there is no
            // folder to resolve it against — so it stays as its text.
            if let url = URL(string: address),
               url.scheme == "http" || url.scheme == "https" || url.isFileURL {
                MarkdownImage(url: url, alt: alt, width: width)
                    .padding(.vertical, 2)
            } else {
                Self.inline(alt.isEmpty ? address : alt)
                    .foregroundStyle(.secondary)
            }
        case .table(let headers, let rows, let alignments):
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
                        .multilineTextAlignment(Self.column(alignments, column).textAlignment)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: Self.column(alignments, column).frameAlignment)
                        .frame(maxHeight: .infinity, alignment: Self.column(alignments, column).frameAlignment)
                        .background(.quaternary.opacity(0.4))
                }
                ForEach(rows.indices, id: \.self) { index in
                    ForEach(headers.indices, id: \.self) { column in
                        Self.inline(column < rows[index].count ? rows[index][column] : "")
                            // The `|:---:|` row the document wrote, which is
                            // what a column of numbers is right-aligned by.
                            .multilineTextAlignment(Self.column(alignments, column).textAlignment)
                            // Take as many lines as the wrapped text needs
                            // rather than being squeezed onto one.
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .frame(maxWidth: .infinity, alignment: Self.column(alignments, column).frameAlignment)
                            // Once cells wrap they no longer agree on a
                            // height, and a fill that stops at the text
                            // leaves the stripe ragged. Stretch every cell
                            // to the tallest one in its row.
                            .frame(maxHeight: .infinity, alignment: Self.column(alignments, column).frameAlignment)
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
        }
    }

    /// A table written with fewer alignments than it has columns still has to
    /// answer for every one of them.
    private static func column(_ alignments: [MarkdownColumn], _ index: Int) -> MarkdownColumn {
        index < alignments.count ? alignments[index] : .leading
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

    /// One line of styled text, with the chip backdrop layered behind it — but
    /// only when there is a chip to draw.
    ///
    /// That condition is the whole point. The backdrop is a *second copy of the
    /// text*, laid out and drawn behind the first, and it used to go behind
    /// every line in the document: a page of pull request comments paid twice
    /// for all of its text so that the handful of lines with a `code` span in
    /// them could have a rounded fill. Most prose has no span at all, and that
    /// half of the work was never visible.
    @MainActor
    fileprivate static func inline(_ source: String, baseSize: CGFloat = MarkdownText.bodySize) -> some View {
        let line = cachedInlineText(source, baseSize: baseSize)
        // Both layers are the same `Text`, and `.font`/`.foregroundStyle` set by
        // the caller reach the backdrop through the environment, so the two
        // always agree on how the text is laid out.
        return line.text.modifier(CodeChipBackdrop(text: line.hasCodeSpan ? line.text : nil))
    }

    /// The styled line, remembered.
    ///
    /// Reading the Markdown in a line is the expensive half of drawing a
    /// comment, and the blocks being cached does not save it: the parse of a
    /// *line* happens here, on the way to a `Text`. A page of comments runs
    /// through this on every pass of a body that has nothing to do with their
    /// text — a build tick, a drag on the panel's seam — so the answer is kept,
    /// the way ``cachedBlocks(in:relativeTo:)`` keeps the blocks above it. The
    /// size is part of the key because a code span is set relative to whatever
    /// block it sits in.
    @MainActor
    private static func cachedInlineText(_ source: String, baseSize: CGFloat) -> Line {
        let key = InlineKey(text: source, size: baseSize)
        if let cached = inlineCache.value(for: key) { return cached }
        let line = inlineText(source, baseSize: baseSize)
        inlineCache.insert(line, for: key)
        return line
    }

    /// A styled line, and whether anything in it needs the chip backdrop.
    fileprivate struct Line {
        var text: Text
        var hasCodeSpan: Bool
    }

    private struct InlineKey: Hashable {
        let text: String
        let size: CGFloat
    }

    /// Every line of every block, so it holds more than the block cache does.
    ///
    /// Sized for a *page*, not for a view: a pull request is drawn in a
    /// `LazyVStack`, so a comment scrolled out of sight is thrown away and built
    /// again on the way back — and every line of it re-read at 46µs a paragraph
    /// if it has fallen out of here by then. A long review runs to a few
    /// thousand lines, and holding them costs a few megabytes.
    @MainActor
    private static var inlineCache = GenerationCache<InlineKey, Line>(limit: 2500)

    /// `baseSize` is the point size of the block the text sits in, so a code
    /// span can be set one point below whatever surrounds it — including inside
    /// a heading, where the run would otherwise be left at body size.
    /// Returns a `Text` rather than an `AttributedString` because the chip
    /// attribute can only be attached per `Text`. Concatenating with `+` still
    /// leaves one `Text`, so the whole thing wraps as a single paragraph.
    private static func inlineText(_ source: String, baseSize: CGFloat) -> Line {
        let parsed = (try? AttributedString(
            markdown: source,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(source)

        // SwiftUI renders `inline code` monospaced but paints nothing behind
        // it, so in a wall of prose it barely reads as code.
        var result = Text(verbatim: "")
        var hasCodeSpan = false
        for run in parsed.runs {
            var piece = AttributedString(parsed[run.range])
            guard run.inlinePresentationIntent?.contains(.code) == true else {
                result = result + Text(piece)
                continue
            }
            hasCodeSpan = true
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
        return Line(text: result, hasCodeSpan: hasCodeSpan)
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
        case .markdown(let text, let base): Self.cachedBlocks(in: text, relativeTo: base, links: links)
        case .parsed(let blocks): blocks
        }
    }

    /// The parse, remembered.
    ///
    /// A view body runs many times over for text that has not changed — a
    /// scroll, a hover, a window resize — and a page of PR comments is a stack
    /// of these. Building a tree on each of those passes is work nobody sees,
    /// so the answer is kept, the way `MarkdownCodeHighlighter` keeps its
    /// colours. Not private: the outline asks for the same blocks the body
    /// draws, and it must not cost a second parse to have them.
    @MainActor
    static func cachedBlocks(in text: String, relativeTo base: URL?, links: MarkdownLinks) -> [Block] {
        // The folder is part of the key, not just the text: the same
        // `![](assets/logo.png)` is a different picture in another repository,
        // and the same `#123` is another repository's pull request. Separate
        // fields rather than one joined string, so a hit costs a hash of what
        // is already there instead of a fresh copy of the whole document.
        let key = BlockKey(text: text, base: base?.path ?? "", links: links)
        if let cached = cache.value(for: key) { return cached }
        let parsed = blocks(in: text, relativeTo: base, links: links)
        cache.insert(parsed, for: key)
        return parsed
    }

    private struct BlockKey: Hashable {
        let text: String
        let base: String
        let links: MarkdownLinks
    }

    @MainActor
    private static var cache = GenerationCache<BlockKey, [Block]>(limit: 500)

    static func blocks(in text: String, relativeTo base: URL? = nil, links: MarkdownLinks = .none) -> [Block] {
        let parsed = MarkdownParser.blocks(in: text, links: links)
        guard let base else { return parsed }
        return resolvingImages(parsed, relativeTo: base)
    }

    /// The headings of a document, for the outline: the level, the words with
    /// their styling taken off, and the index of the block they came from —
    /// which is what ``headingID(_:)`` names and the scroll view scrolls to.
    @MainActor
    static func outline(of blocks: [Block]) -> [(index: Int, level: Int, title: String)] {
        blocks.enumerated().compactMap { index, block in
            guard case .heading(let level, let text) = block else { return nil }
            let plain = (try? AttributedString(
                markdown: text,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            )).map { String($0.characters) } ?? text
            let title = plain.trimmingCharacters(in: .whitespaces)
            return title.isEmpty ? nil : (index, level, title)
        }
    }

    /// Turns `![](assets/preview.jpeg)` into the file it means.
    ///
    /// A README is written to be read beside its own folder, and the pictures in
    /// it are paths into that folder rather than addresses anything can fetch.
    /// Nothing downstream has to know that happened: the block carries a
    /// `file://` address, and the picture is loaded, cached and written into the
    /// PDF by the same code an `https://` one goes through.
    ///
    /// It is done here rather than in the view because the parse is what is
    /// cached, and because `MarkdownPDF` walks these very blocks.
    private static func resolvingImages(_ blocks: [Block], relativeTo base: URL) -> [Block] {
        blocks.map { block in
            switch block {
            case .image(let address, let alt, let width):
                guard let file = localFile(for: address, relativeTo: base) else { return block }
                return .image(url: file.absoluteString, alt: alt, width: width)
            // A picture inside a quote, a folded section or a list item is
            // still a picture.
            case .quote(let alert, let nested):
                return .quote(alert, resolvingImages(nested, relativeTo: base))
            case .disclosure(let summary, let isOpen, let nested):
                return .disclosure(
                    summary: summary,
                    isOpen: isOpen,
                    blocks: resolvingImages(nested, relativeTo: base)
                )
            case .list(var list):
                list.items = list.items.map { item in
                    var resolved = item
                    resolved.blocks = resolvingImages(item.blocks, relativeTo: base)
                    return resolved
                }
                return .list(list)
            default:
                return block
            }
        }
    }

    /// The file a Markdown address points at, when it points at one at all.
    ///
    /// `https://…` and anything else with a scheme is somebody else's to fetch.
    /// A leading `/` means the repository's root the way GitHub reads it, not
    /// the disk's, so it is resolved against the checkout the file sits in and
    /// dropped when there is none — `/etc/passwd` is not what a README meant.
    ///
    /// Only a path that is actually there becomes a picture. A broken one stays
    /// the text the author wrote, which is what shows them it is broken.
    private static func localFile(for address: String, relativeTo base: URL) -> URL? {
        guard !address.isEmpty, URL(string: address)?.scheme == nil else { return nil }
        // The `#fragment` and `?query` a host would answer without, and the
        // escapes a path with a space in it is written with.
        var path = address
        if let hash = path.firstIndex(of: "#") { path = String(path[..<hash]) }
        if let question = path.firstIndex(of: "?") { path = String(path[..<question]) }
        path = path.removingPercentEncoding ?? path
        guard !path.isEmpty else { return nil }

        let directory = base.deletingLastPathComponent()
        let resolved: URL
        if path.hasPrefix("/") {
            guard let root = repositoryRoot(above: directory) else { return nil }
            resolved = root.appending(path: String(path.dropFirst()))
        } else {
            resolved = directory.appending(path: path)
        }
        let file = resolved.standardizedFileURL
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }

    /// The checkout the folder sits in, found the way git finds it — the nearest
    /// `.git` at or above it. The count is only a backstop; a path has an end.
    private static func repositoryRoot(above directory: URL) -> URL? {
        var folder = directory.standardizedFileURL
        for _ in 0..<64 {
            if FileManager.default.fileExists(atPath: folder.appending(path: ".git").path) {
                return folder
            }
            let parent = folder.deletingLastPathComponent().standardizedFileURL
            if parent == folder { return nil }
            folder = parent
        }
        return nil
    }

    /// True when `blocks` — or anything nested in them — holds a diagram.
    /// `MarkdownPDF` asks before copying mermaid in beside the page.
    static func containsDiagram(_ blocks: [Block]) -> Bool {
        blocks.contains { block in
            switch block {
            case .mermaid: true
            case .quote(_, let nested), .disclosure(_, _, let nested): containsDiagram(nested)
            case .list(let list): list.items.contains { containsDiagram($0.blocks) }
            default: false
            }
        }
    }
}

// MARK: - Environment

/// How deep in a list the text being drawn sits. It travels in the environment
/// rather than as a parameter because a sub-list is drawn by a nested
/// `MarkdownText` that was handed blocks, not a depth — and the same is true of
/// a list inside a quote or a `<details>` section.
private struct MarkdownListDepthKey: EnvironmentKey {
    static let defaultValue = 0
}

/// Where a `#123` and an `@name` in the Markdown being drawn point. Nothing by
/// default: a release note has no repository behind it, and a `#123` that
/// cannot be resolved is better left as the words it was written as.
private struct MarkdownLinksKey: EnvironmentKey {
    static let defaultValue = MarkdownLinks.none
}

/// What ticking a checkbox does, and what it writes to.
///
/// `perform` takes the 1-based source line the item was written on and the state
/// it should end up in. `target` is what those lines belong to — a file's path,
/// a comment's id — and it is the whole of this type's equality.
///
/// That equality is the point of the type existing. A closure is never equal to
/// another closure, so an action rebuilt on each pass reads as a change to
/// everything under it: a page of pull request comments would rebuild all of its
/// text on any redraw at all, which is exactly how it came to stutter under a
/// scroll. Two actions writing to the same place are the same action, whatever
/// closure was made this time round.
struct MarkdownTaskToggle: Equatable {
    let target: String
    /// The text this action was built against.
    ///
    /// It is here because `target` alone is *too* stable. An action that reads
    /// its source when it runs would need nothing else — but a comment's does
    /// not: the words it flips are a `String` captured when the closure was
    /// made. Equal on `target` alone, the first action would be kept for as
    /// long as the comment kept its id, so a second tick would be computed
    /// against the body from before the first one and posted back over it.
    /// Comparing the content is what retires the stale closure, and it costs
    /// nothing in the ordinary case: the same string, so `==` answers on the
    /// pointer.
    let content: String
    let perform: (Int, Bool) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.target == rhs.target && lhs.content == rhs.content
    }
}

/// Nothing by default: a release note and a `<details>` section from a bot have
/// checkboxes nobody can write back to, and a box that cannot be ticked should
/// not look as though it can.
struct MarkdownTaskToggleKey: EnvironmentKey {
    // `nil` is as shared-mutable as this gets, but the type it is nil *of*
    // holds a closure, and a closure is not `Sendable`. The environment is read
    // on the main actor and nowhere else.
    nonisolated(unsafe) static let defaultValue: MarkdownTaskToggle? = nil
}

extension EnvironmentValues {
    var markdownListDepth: Int {
        get { self[MarkdownListDepthKey.self] }
        set { self[MarkdownListDepthKey.self] = newValue }
    }

    var markdownLinks: MarkdownLinks {
        get { self[MarkdownLinksKey.self] }
        set { self[MarkdownLinksKey.self] = newValue }
    }

    var markdownTaskToggle: MarkdownTaskToggle? {
        get { self[MarkdownTaskToggleKey.self] }
        set { self[MarkdownTaskToggleKey.self] = newValue }
    }
}

/// Names a block so the outline can scroll to it, and leaves it alone otherwise.
private struct HeadingAnchor: ViewModifier {
    let id: String?

    func body(content: Content) -> some View {
        if let id {
            content.id(id)
        } else {
            content
        }
    }
}

// MARK: - Lists

/// One list, drawn as its items — each of which is a document of its own.
///
/// The nesting is real: a sub-list, a second paragraph and a fenced block under
/// a bullet are blocks of the item, so they are drawn by a nested `MarkdownText`
/// inside the item's own column. That is what lines a wrapped line up under the
/// text rather than under the bullet, and what indents a sub-list by exactly the
/// width of its parent's marker.
private struct MarkdownListView: View {
    let list: MarkdownList
    /// Read here rather than in `MarkdownText`, so that every paragraph in the
    /// document does not take a dependency on two values only a list uses.
    @Environment(\.markdownListDepth) private var depth
    @Environment(\.markdownTaskToggle) private var onToggle

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(list.items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    marker(for: item, at: index)
                    content(of: item)
                        // No strikethrough on a ticked item: the box already
                        // says it is done, and struck-through text is the
                        // harder to read the more there is of it.
                        .foregroundStyle(item.isDone == true ? .secondary : .primary)
                }
                .environment(\.markdownListDepth, depth + 1)
            }
        }
    }

    /// Nearly every item is one paragraph, and that one is drawn as the line it
    /// is. The nested `MarkdownText` is what carries a sub-list, a second
    /// paragraph or a fence — and it is a whole stack, a `ForEach` and a round
    /// of environment reads, so a long checklist is worth not paying it for.
    @ViewBuilder
    private func content(of item: MarkdownList.Item) -> some View {
        if item.blocks.count == 1, case .paragraph(let text) = item.blocks[0] {
            MarkdownText.inline(text)
        } else {
            MarkdownText(blocks: item.blocks)
        }
    }

    @ViewBuilder
    private func marker(for item: MarkdownList.Item, at index: Int) -> some View {
        if let isDone = item.isDone {
            MarkdownCheckbox(
                isDone: isDone,
                // A box with no source line behind it — one that came out of a
                // bot's HTML — is drawn but not offered.
                onToggle: item.line.flatMap { line in
                    onToggle.map { toggle in { toggle.perform(line, !isDone) } }
                }
            )
        } else if list.isOrdered {
            Text("\(list.start + index).")
                .foregroundStyle(.secondary)
                .monospacedDigit()
        } else {
            Text(Self.bullet(at: depth))
                .foregroundStyle(.secondary)
        }
    }

    /// A different mark at each level, the way a printed list distinguishes
    /// them — the indent alone is easy to lose in a long item.
    private static func bullet(at depth: Int) -> String {
        switch depth {
        case 0: "•"
        case 1: "◦"
        default: "▪"
        }
    }
}

/// The box itself. A button when there is somewhere to write the answer, and
/// otherwise the picture of one.
private struct MarkdownCheckbox: View {
    let isDone: Bool
    let onToggle: (() -> Void)?

    var body: some View {
        Group {
            if let onToggle {
                Button(action: onToggle) { box }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .help(isDone ? "Mark as not done" : "Mark as done")
            } else {
                box
            }
        }
        // The square turns about its own middle, which sits a little above the
        // baseline the row is aligned on.
        .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 3 }
        // A click on the box is a click on the box, not the start of a
        // selection dragged across the list.
        .textSelection(.disabled)
    }

    private var box: some View {
        Image(systemName: isDone ? "checkmark.square.fill" : "square")
            .foregroundStyle(isDone ? Color.green : Color.secondary)
            .imageScale(.small)
            .contentShape(Rectangle())
    }
}

// MARK: - Code

/// A fenced block, with the one thing people do to a fenced block on it.
///
/// Everything in the preview is selectable, but a code block is the one thing
/// that is copied *whole* — and selecting exactly it, with no line of the prose
/// either side, is fiddly in a wall of text.
private struct MarkdownCodeBlock: View {
    let code: String
    let text: Text

    var body: some View {
        ScrollView(.horizontal) {
            // Coloured by the editor's own tree-sitter setup when the fence
            // names a language we have a grammar for, plain when it does not.
            text
                .font(.system(.callout, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                // Room for the button, so the last words of a long first line
                // do not run under it.
                .padding(.trailing, 28)
        }
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
        // The fill alone is faint against a dark viewer; the outline is
        // what actually marks where the block starts and stops.
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary, lineWidth: 1))
        // The hover lives in the overlay, not here. Scrolling drags the whole
        // document under a pointer that never moved, so every block the pointer
        // crosses reports a hover — and with the state on this view, each of
        // those rebuilt the fence and its coloured text. In there it rebuilds
        // one button.
        .overlay { MarkdownCopyButton(code: code) }
    }
}

/// The copy button, and the hover that reveals it.
///
/// Everything in the preview is selectable, but a code block is the one thing
/// that is copied *whole* — and selecting exactly it, with no line of the prose
/// either side, is fiddly in a wall of text.
private struct MarkdownCopyButton: View {
    let code: String

    @State private var isHovered = false
    @State private var hasCopied = false

    var body: some View {
        // Shown on hover only: a page of fenced examples otherwise wears a row
        // of buttons nobody asked for. It stays up while it says "Copied", so
        // the word is readable after the pointer has moved on.
        button
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .contentShape(Rectangle())
            // Nothing here takes a click except the button, so a drag that
            // starts on the code still selects it.
            .allowsHitTesting(isHovered || hasCopied)
            .onHover { isHovered = $0 }
    }

    @ViewBuilder
    private var button: some View {
        if isHovered || hasCopied {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(code, forType: .string)
                hasCopied = true
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    hasCopied = false
                }
            } label: {
                Image(systemName: hasCopied ? "checkmark" : "doc.on.doc")
                    .font(.caption)
                    .foregroundStyle(hasCopied ? Color.green : Color.secondary)
                    .padding(5)
                    .background(.background.opacity(0.8), in: RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help(hasCopied ? "Copied" : "Copy this block")
            .padding(5)
            .transition(.opacity)
        }
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
