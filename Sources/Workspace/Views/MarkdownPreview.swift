import SwiftUI

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
            Text(inline(text))
                .font(headingFont(level))
                .padding(.top, level <= 2 ? 8 : 4)
        case .paragraph(let text):
            Text(inline(text))
        case .bullet(let indent, let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(indent > 0 ? "◦" : "•").foregroundStyle(.secondary)
                Text(inline(text))
            }
            .padding(.leading, CGFloat(indent) * 16)
        case .numbered(let indent, let number, let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(number).")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Text(inline(text))
            }
            .padding(.leading, CGFloat(indent) * 16)
        case .task(let done, let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: done ? "checkmark.square.fill" : "square")
                    .foregroundStyle(done ? Color.green : Color.secondary)
                    .imageScale(.small)
                Text(inline(text))
                    .strikethrough(done, color: .secondary)
                    .foregroundStyle(done ? .secondary : .primary)
            }
        case .quote(let text):
            HStack(alignment: .top, spacing: 10) {
                Rectangle().fill(.quaternary).frame(width: 3)
                Text(inline(text)).foregroundStyle(.secondary)
            }
        case .code(let code):
            ScrollView(.horizontal) {
                Text(code)
                    .font(.system(.callout, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
        case .table(let headers, let rows):
            ScrollView(.horizontal) {
                Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
                    GridRow {
                        ForEach(headers.indices, id: \.self) { column in
                            Text(inline(headers[column]))
                                .font(.callout.weight(.semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                        }
                    }
                    .background(.quaternary.opacity(0.4))
                    ForEach(rows.indices, id: \.self) { index in
                        Divider()
                        GridRow {
                            ForEach(rows[index].indices, id: \.self) { column in
                                Text(inline(rows[index][column]))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                            }
                        }
                        .background(
                            index.isMultiple(of: 2)
                                ? AnyShapeStyle(.clear)
                                : AnyShapeStyle(.quaternary.opacity(0.15))
                        )
                    }
                }
            }
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

    private func inline(_ source: String) -> AttributedString {
        (try? AttributedString(
            markdown: source,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(source)
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
