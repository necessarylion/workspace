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
    let text: String

    private enum Block {
        case heading(level: Int, text: String)
        case paragraph(String)
        case bullet(indent: Int, text: String)
        case numbered(indent: Int, number: String, text: String)
        case task(done: Bool, text: String)
        case quote(String)
        case code(String)
        case table(headers: [String], rows: [[String]])
        case rule
        case spacer
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
            inline(text, baseSize: headingSize(level))
                .font(headingFont(level))
                .padding(.top, level <= 2 ? 8 : 4)
        case .paragraph(let text):
            inline(text)
        case .bullet(let indent, let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(indent > 0 ? "◦" : "•").foregroundStyle(.secondary)
                inline(text)
            }
            .padding(.leading, CGFloat(indent) * 16)
        case .numbered(let indent, let number, let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(number).")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                inline(text)
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
                inline(text)
                    .foregroundStyle(done ? .secondary : .primary)
            }
        case .quote(let text):
            HStack(alignment: .top, spacing: 10) {
                Rectangle().fill(.quaternary).frame(width: 3)
                inline(text).foregroundStyle(.secondary)
            }
        case .code(let code):
            ScrollView(.horizontal) {
                Text(code)
                    .font(.system(.callout, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
            // The fill alone is faint against a dark viewer; the outline is
            // what actually marks where the block starts and stops.
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary, lineWidth: 1))
        case .table(let headers, let rows):
            // No horizontal scroll view around this: one would offer the grid
            // unbounded width, so a cell would never wrap and a wide table would
            // scroll instead of fitting. Bounded by the pane, the columns share
            // what there is and long cells wrap.
            Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
                // The fill goes on each cell, not on the `GridRow`: a row
                // background only covers the cells' own widths, which leaves
                // unpainted gaps wherever a column is wider than its text.
                // `maxWidth: .infinity` makes a cell take the whole column.
                GridRow {
                    ForEach(headers.indices, id: \.self) { column in
                        inline(headers[column])
                            .font(.callout.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .frame(maxHeight: .infinity, alignment: .topLeading)
                            .background(.quaternary.opacity(0.4))
                    }
                }
                ForEach(rows.indices, id: \.self) { index in
                    Divider()
                    GridRow {
                        ForEach(rows[index].indices, id: \.self) { column in
                            inline(rows[index][column])
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
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
            // The cells stretch to their row, so the grid itself has to be
            // pinned to its natural height or that `.infinity` would make the
            // whole table greedy.
            .fixedSize(horizontal: false, vertical: true)
            .background(.quaternary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary, lineWidth: 1))
        case .rule:
            Divider()
        case .spacer:
            Spacer().frame(height: 2)
        }
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
    private func inline(_ source: String, baseSize: CGFloat = MarkdownText.bodySize) -> some View {
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
    private func inlineText(_ source: String, baseSize: CGFloat) -> Text {
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

    private var blocks: [Block] {
        var result: [Block] = []
        var codeBuffer: [String] = []
        var inCode = false
        var tableBuffer: [[String]] = []

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
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if !inCode, trimmed.hasPrefix("|"), trimmed.dropFirst().contains("|") {
                tableBuffer.append(tableCells(trimmed))
                continue
            }
            flushTable()

            if trimmed.hasPrefix("```") {
                if inCode {
                    result.append(.code(codeBuffer.joined(separator: "\n")))
                    codeBuffer.removeAll()
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

            if trimmed.isEmpty {
                result.append(.spacer)
            } else if trimmed == "---" || trimmed == "***" {
                result.append(.rule)
            } else if trimmed.hasPrefix("#") {
                let level = trimmed.prefix(while: { $0 == "#" }).count
                let title = trimmed.dropFirst(level).trimmingCharacters(in: .whitespaces)
                result.append(.heading(level: min(level, 6), text: title))
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
                let rest = String(trimmed.dropFirst(2))
                if rest.hasPrefix("[ ] ") {
                    result.append(.task(done: false, text: String(rest.dropFirst(4))))
                } else if rest.hasPrefix("[x] ") || rest.hasPrefix("[X] ") {
                    result.append(.task(done: true, text: String(rest.dropFirst(4))))
                } else {
                    result.append(.bullet(indent: indent, text: rest))
                }
            } else if let ordered = orderedItem(trimmed) {
                result.append(.numbered(indent: indent, number: ordered.number, text: ordered.text))
            } else if trimmed.hasPrefix(">") {
                let rest = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
                result.append(.quote(rest))
            } else {
                result.append(.paragraph(trimmed))
            }
        }

        flushTable()
        if inCode, !codeBuffer.isEmpty {
            result.append(.code(codeBuffer.joined(separator: "\n")))
        }
        return result
    }

    /// "| a | b |" → ["a", "b"].
    private func tableCells(_ line: String) -> [String] {
        var inner = Substring(line)
        if inner.hasPrefix("|") { inner = inner.dropFirst() }
        if inner.hasSuffix("|") { inner = inner.dropLast() }
        return inner
            .split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// "3. text" or "3) text" → ("3", "text"); nil when not an ordered item.
    private func orderedItem(_ line: String) -> (number: String, text: String)? {
        let digits = line.prefix(while: \.isNumber)
        guard !digits.isEmpty, digits.count <= 4 else { return nil }
        let rest = line.dropFirst(digits.count)
        guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
        return (String(digits), rest.dropFirst(2).trimmingCharacters(in: .whitespaces))
    }
}
