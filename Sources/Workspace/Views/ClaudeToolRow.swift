import AppKit
import SwiftUI

/// One tool call: a status dot, the tool's name, the one argument worth
/// reading — and under it what the call actually did.
///
/// What "did" means depends on the tool, which is the point. An edit is its
/// diff, coloured by the same machinery the diff viewer uses, because two
/// changed words are the whole content of the call. A command is a couple of
/// lines of output and a count, because the other four hundred lines are not
/// what you are reading the transcript for — they are a click away when they
/// are. A read is neither: the file name and the lines it took are the whole
/// story, and printing the file back at you says nothing.
struct ClaudeToolRow: View {
    @Bindable var call: ClaudeToolCall
    let openFile: (String) -> Void
    /// Said once this row knows how tall it is. A diff is built a beat after
    /// the row appears, and by then the transcript has already parked itself
    /// on what it thought was the bottom.
    var didResize: () -> Void = {}

    /// The diff, once built. Nil for a tool that does not change a file.
    @State private var edit: ClaudeToolEdit?
    /// The result, measured and cut down. Nil until the call has returned.
    @State private var output: ClaudeToolOutput?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, Self.gutter)
            }
            content
                .padding(.leading, Self.gutter)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Both are read from the call rather than watched: the input is settled
        // before the tool runs and the result lands once, so the only moment
        // either can change is the one this is keyed on.
        .task(id: call.isRunning) {
            rebuild()
            // A beat before saying so: the rows this just built have to be laid
            // out before the transcript is worth scrolling to the foot of.
            try? await Task.sleep(for: .milliseconds(50))
            didResize()
        }
    }

    // MARK: - The row itself

    /// Folding the row open and shut. Everything that offers it — the header,
    /// and the line at the foot of a block that says what is not on screen —
    /// goes through this, so the offer is never made by something that cannot
    /// answer it.
    private func toggle() {
        withAnimation(.easeInOut(duration: 0.14)) { call.isExpanded.toggle() }
    }

    private var header: some View {
        Button(action: toggle) {
            HStack(spacing: 0) {
                status
                    .frame(width: Self.gutter, alignment: .leading)
                Text(call.name)
                    .font(.callout.weight(.bold))
                    .foregroundStyle(call.isError ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
                if !argument.isEmpty {
                    Text(argument)
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        // The end of a path and the end of a command are both
                        // the half worth keeping.
                        .truncationMode(.middle)
                        .padding(.leading, 8)
                }
                Spacer(minLength: 8)
                Image(systemName: call.isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // The transcript is selectable throughout, and selectable text eats the
        // click before the button under it ever hears about it — which left the
        // row opening only where you hit the gap between the name and the
        // chevron. Nobody wants to copy the word "Bash" anyway.
        .textSelection(.disabled)
        .pointerCursor()
        .help(call.isExpanded ? "Fold this call away" : "Show everything this call was given and returned")
    }

    /// Running, done, or failed — the one thing a row says before it says
    /// anything else, and the reason the tool's own glyph is gone: a column of
    /// dots is skimmable in a way a column of different icons is not.
    @ViewBuilder
    private var status: some View {
        if call.isRunning {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.55)
                .frame(width: 8, height: 8)
        } else {
            Circle()
                .fill(call.isError ? Color.red : Self.done)
                .frame(width: 7, height: 7)
        }
    }

    // MARK: - What the call did

    @ViewBuilder
    private var content: some View {
        if let edit, !edit.lines.isEmpty {
            // Side by side when there is a side to put things on. A pure
            // insertion — a `Write`, or an edit that only adds — has nothing
            // in its left column, and half a chat pane of empty is a worse
            // reading of the same change.
            if edit.isSplittable {
                ClaudeSplitDiffBlock(
                    rows: edit.rows,
                    limit: call.isExpanded ? nil : Self.foldedDiffRows,
                    toggle: toggle
                )
            } else {
                ClaudeDiffBlock(
                    lines: edit.lines,
                    limit: call.isExpanded ? nil : Self.foldedDiffLines,
                    toggle: toggle
                )
            }
        }
        if let output, output.isError || (showsOutput && !output.preview.isEmpty) {
            ClaudeOutputBlock(output: output, isExpanded: call.isExpanded, toggle: toggle)
        }
        if call.isExpanded {
            expansion
        }
    }

    /// The arguments as they were given, which the tidied header line is a
    /// summary of — and for an edit, the only place the whole path appears.
    @ViewBuilder
    private var expansion: some View {
        if let arguments = argumentText, !arguments.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text("INPUT")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(arguments)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        if let path = openablePath {
            Button {
                openFile(path)
            } label: {
                Label("Open \((path as NSString).lastPathComponent)", systemImage: "arrow.up.forward.square")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .pointerCursor()
            .padding(.top, 2)
        }
    }

    /// Whether the output is worth showing under the row at all. A command, a
    /// search and a listing are read *for* what they print; a read or an edit
    /// prints its own input back, which is either already on screen above or
    /// not worth the room.
    private var showsOutput: Bool {
        switch call.name {
        case "Bash", "BashOutput", "Grep", "Glob", "LS", "WebFetch", "WebSearch": true
        default: call.isExpanded
        }
    }

    // MARK: - Wording

    /// The argument the row is named by: the file, the command, the pattern.
    private var argument: String {
        switch call.name {
        case "Read", "NotebookEdit":
            [fileName, readRange].compactMap(\.self).joined(separator: " ")
        case "Edit", "MultiEdit", "Write":
            fileName ?? ""
        case "Grep":
            [call.input["pattern"]?.stringValue, searchScope].compactMap(\.self).joined(separator: " ")
        default:
            firstLine(of: call.summary)
        }
    }

    /// The line under the name: what changed, or how much came back.
    private var detail: String? {
        if let edit, edit.added > 0 || edit.removed > 0 {
            return edit.description
        }
        guard let output, !output.isError else { return nil }
        switch call.name {
        case "Read", "NotebookEdit":
            // Only when the header does not already say which lines were taken.
            return readRange == nil ? measured(output.lineCount, "line") : nil
        case "Grep", "Glob", "LS":
            return measured(output.lineCount, "result")
        case "Bash", "BashOutput":
            return output.lineCount > Self.previewLines
                ? measured(output.lineCount, "line") + " of output"
                : nil
        default:
            return nil
        }
    }

    private func measured(_ count: Int, _ noun: String) -> String {
        "\(count) \(noun)\(count == 1 ? "" : "s")"
    }

    /// The file the row is about, by its name alone. The folders are in the
    /// input the row unfolds into: a transcript is read down the left edge, and
    /// a column of repeated paths pushes the one word that differs off it.
    private var fileName: String? {
        path.map { ($0 as NSString).lastPathComponent }
    }

    private var path: String? {
        call.input["file_path"]?.stringValue ?? call.input["path"]?.stringValue
    }

    /// "(lines 127-146)", when the call asked for part of a file.
    private var readRange: String? {
        guard let offset = call.input["offset"]?.intValue else { return nil }
        guard let limit = call.input["limit"]?.intValue, limit > 0 else { return "(from line \(offset))" }
        return "(lines \(offset)-\(offset + limit - 1))"
    }

    /// Where a search ran, when it was pointed somewhere in particular.
    private var searchScope: String? {
        guard let path else { return nil }
        return "in \((path as NSString).lastPathComponent)"
    }

    private func firstLine(of text: String) -> String {
        text.split(separator: "\n").first.map(String.init) ?? ""
    }

    /// What the tool was called with — the confirmed arguments once they are
    /// parsed, and the half-written JSON while they are still arriving.
    private var argumentText: String? {
        if case .object(let fields) = call.input, !fields.isEmpty {
            return fields
                .sorted { $0.key < $1.key }
                .map { "\($0.key): \($0.value.displayText)" }
                .joined(separator: "\n")
        }
        return call.partialInput.isEmpty ? nil : call.partialInput
    }

    /// The file this call is about, when it is about one, so the row can open it
    /// in the editor next door.
    private var openablePath: String? {
        guard let path, FileManager.default.fileExists(atPath: path) else { return nil }
        return path
    }

    private func rebuild() {
        edit = ClaudeToolEdit(call: call)
        output = ClaudeToolOutput(call: call)
    }

    /// The dot's column, which everything under the header lines up with.
    private static let gutter: CGFloat = 20
    /// How much of a diff a folded row shows. Two or three lines is the usual
    /// edit; past a dozen the row is a file, and the file is what to open.
    private static let foldedDiffLines = 14
    /// The same allowance in split view, where one row is one line of the
    /// change rather than one side of it.
    private static let foldedDiffRows = 10
    private static let previewLines = 3
    private static let done = Color(red: 0.33, green: 0.78, blue: 0.45)
}

// MARK: - The diff

/// The changed lines of an edit, in the diff viewer's colours.
///
/// Full-bleed rows inside a bordered box: the wash has to reach both edges to
/// read as a line of a diff rather than as highlighted text.
private struct ClaudeDiffBlock: View {
    let lines: [ClaudeDiffLine]
    /// How many lines to draw, or nil for all of them.
    let limit: Int?
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(shown) { line in
                HStack(alignment: .top, spacing: 6) {
                    Text(line.marker)
                        .foregroundStyle(.tertiary)
                        .frame(width: 7, alignment: .leading)
                    Text(line.text)
                        .textSelection(.enabled)
                        // Wrapped rather than scrolled sideways: a chat column
                        // is narrow, and a diff you have to drag to read is one
                        // nobody reads.
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.system(size: 11.5, design: .monospaced))
                .padding(.horizontal, 8)
                .padding(.vertical, 1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(line.background)
            }
            if hidden > 0 {
                ClaudeMoreLink("Show all \(lines.count) lines", action: toggle)
                    .padding(.horizontal, 8)
                    .padding(.top, 3)
            }
        }
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.18))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary.opacity(0.5), lineWidth: 1)
        }
    }

    private var shown: [ClaudeDiffLine] {
        guard let limit, lines.count > limit else { return lines }
        return Array(lines.prefix(limit))
    }

    private var hidden: Int { lines.count - shown.count }
}

/// The same change with the before on the left and the after on the right —
/// the layout the diff viewer opens on, cut down to what a chat column can
/// hold: no gutter (an `Edit` never says which line it changed), no comment
/// buttons, and text that wraps instead of running off the side.
private struct ClaudeSplitDiffBlock: View {
    let rows: [DiffRow]
    /// How many rows to draw, or nil for all of them.
    let limit: Int?
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(shown) { row in
                    // Pinned to its natural height so both halves stretch to
                    // exactly it; left alone the two cells round separately and
                    // leave a hairline of background between coloured bands.
                    HStack(alignment: .top, spacing: 0) {
                        cell(text(row, .old), background(row, .old))
                        cell(text(row, .new), background(row, .new))
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            // Down the seam rather than between the cells: a divider in the row
            // would take part in working out how tall the row is.
            .overlay {
                Rectangle().fill(.quaternary).frame(width: 1)
            }
            if hidden > 0 {
                ClaudeMoreLink("Show all \(rows.count) lines", action: toggle)
                    .padding(.horizontal, 8)
                    .padding(.top, 3)
            }
        }
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.18))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary.opacity(0.5), lineWidth: 1)
        }
    }

    /// Two flexible cells with nothing else in the stack, so each takes half
    /// the column whatever the pane is doing — no measuring needed.
    private func cell(_ text: AttributedString, _ background: Color) -> some View {
        Text(text)
            .font(.system(size: 11.5, design: .monospaced))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(.horizontal, 8)
            .padding(.vertical, 1)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(background)
    }

    private enum Side { case old, new }

    private func text(_ row: DiffRow, _ side: Side) -> AttributedString {
        switch side {
        case .old:
            (row.oldHighlighted ?? AttributedString(row.oldText ?? ""))
                .markingWords(row.oldWordRanges, with: DiffColors.removedWord)
        case .new:
            (row.newHighlighted ?? AttributedString(row.newText ?? ""))
                .markingWords(row.newWordRanges, with: DiffColors.addedWord)
        }
    }

    private func background(_ row: DiffRow, _ side: Side) -> Color {
        switch row.kind {
        case .context: .clear
        case .added: side == .new ? DiffColors.addedLine : .clear
        case .removed: side == .old ? DiffColors.removedLine : .clear
        case .changed: side == .old ? DiffColors.removedLine : DiffColors.addedLine
        }
    }

    private var shown: [DiffRow] {
        guard let limit, rows.count > limit else { return rows }
        return Array(rows.prefix(limit))
    }

    private var hidden: Int { rows.count - shown.count }
}

// MARK: - The output

/// What a command printed: the head of it while the row is folded, all of it
/// (up to a sane ceiling) once it is open.
private struct ClaudeOutputBlock: View {
    let output: ClaudeToolOutput
    let isExpanded: Bool
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ScrollView(.horizontal, showsIndicators: false) {
                Text(isExpanded ? output.full : output.preview.joined(separator: "\n"))
                    .font(.caption.monospaced())
                    .foregroundStyle(output.isError ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let rest {
                if isExpanded {
                    // Nothing to click: the row is already as open as it goes,
                    // and the rest of the output is not being kept from you by
                    // a fold. It is simply too much to draw.
                    Text(rest)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } else {
                    ClaudeMoreLink(rest, action: toggle)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.18))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    output.isError ? AnyShapeStyle(.red.opacity(0.35)) : AnyShapeStyle(.quaternary.opacity(0.5)),
                    lineWidth: 1
                )
        }
    }

    /// What is not on screen, said in the one line that offers it.
    private var rest: String? {
        let drawn = isExpanded ? output.shownWhenOpen : output.preview.count
        let hidden = output.lineCount - drawn
        guard hidden > 0 else { return nil }
        return isExpanded
            ? "\(hidden) more lines, not shown"
            : "Show all \(output.lineCount) lines"
    }
}

/// The line at the foot of a block that offers the rest of it.
///
/// A button, not a sentence about clicking: the first thing anyone does when a
/// row says there is more is click the words saying so, and words are where
/// the pointer already is.
private struct ClaudeMoreLink: View {
    let title: String
    let action: () -> Void

    @State private var isHovering = false

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                Text(title)
                    .font(.caption2)
            }
            .foregroundStyle(isHovering ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .textSelection(.disabled)
        .onHover { isHovering = $0 }
        .pointerCursor()
    }
}

// MARK: - Building the diff

/// One drawn line of an edit's diff. A changed line is two of these: the old
/// and the new, the way a unified diff shows it.
struct ClaudeDiffLine: Identifiable {
    let id: Int
    let marker: String
    let text: AttributedString
    let background: Color
}

/// The edit a tool call describes, turned into something to draw.
///
/// It goes through the app's own diff machinery rather than a comparison
/// written for this row: a synthetic patch into ``DiffParser`` buys the
/// word-level ranges, and ``DiffHighlighter`` colours the result by the file's
/// real language, so an edit in the chat looks like the same edit in the diff
/// viewer.
@MainActor
struct ClaudeToolEdit {
    /// The change as the parser paired it up, for the side-by-side layout.
    var rows: [DiffRow] = []
    /// The same change flattened the way `git diff` prints it, for the layout
    /// that has no second column to fill.
    var lines: [ClaudeDiffLine] = []
    var added = 0
    var removed = 0

    /// Whether there is a before worth showing beside the after.
    var isSplittable: Bool {
        rows.contains { $0.kind == .removed || $0.kind == .changed }
    }

    /// "Added 2 lines", "Removed 1 line", "Added 3 lines, removed 1".
    var description: String {
        let parts = [
            added > 0 ? "Added \(added) line\(added == 1 ? "" : "s")" : nil,
            removed > 0 ? (added > 0 ? "removed \(removed)" : "Removed \(removed) line\(removed == 1 ? "" : "s")") : nil,
        ].compactMap(\.self)
        return parts.joined(separator: ", ")
    }

    /// Nil for a call that changes no file, and for one whose arguments have
    /// not finished arriving.
    init?(call: ClaudeToolCall) {
        guard let patch = Self.patch(for: call) else { return nil }
        let parsed = DiffParser.parse(patch)
        guard let file = parsed.files.first else { return nil }
        let coloured = DiffHighlighter.highlight(file)

        rows = coloured.hunks.flatMap(\.rows)

        var next = 0
        for row in rows {
            switch row.kind {
            case .context:
                append(&next, marker: " ", row.oldHighlighted, row.oldText, [], .clear, DiffColors.removedWord)
            case .removed:
                removed += 1
                append(&next, marker: "−", row.oldHighlighted, row.oldText, row.oldWordRanges, DiffColors.removedLine, DiffColors.removedWord)
            case .added:
                added += 1
                append(&next, marker: "+", row.newHighlighted, row.newText, row.newWordRanges, DiffColors.addedLine, DiffColors.addedWord)
            case .changed:
                added += 1
                removed += 1
                append(&next, marker: "−", row.oldHighlighted, row.oldText, row.oldWordRanges, DiffColors.removedLine, DiffColors.removedWord)
                append(&next, marker: "+", row.newHighlighted, row.newText, row.newWordRanges, DiffColors.addedLine, DiffColors.addedWord)
            }
        }
        guard !lines.isEmpty else { return nil }
    }

    private mutating func append(
        _ next: inout Int,
        marker: String,
        _ highlighted: AttributedString?,
        _ plain: String?,
        _ words: [Range<Int>],
        _ background: Color,
        _ wordColor: Color
    ) {
        let text = (highlighted ?? AttributedString(plain ?? "")).markingWords(words, with: wordColor)
        lines.append(ClaudeDiffLine(id: next, marker: marker, text: text, background: background))
        next += 1
    }

    /// A unified patch for the call, or nil if it does not describe an edit.
    ///
    /// The line numbers are made up — an `Edit` says what it replaced, never
    /// where — which is why the drawn rows carry no gutter.
    private static func patch(for call: ClaudeToolCall) -> String? {
        let name = (call.input["file_path"]?.stringValue as NSString?)?.lastPathComponent ?? "file.txt"
        var body: [String] = []

        switch call.name {
        case "Edit":
            guard let old = call.input["old_string"]?.stringValue,
                  let new = call.input["new_string"]?.stringValue
            else { return nil }
            body = hunk(old: old, new: new)
        case "MultiEdit":
            guard let edits = call.input["edits"]?.arrayValue else { return nil }
            for edit in edits {
                guard let old = edit["old_string"]?.stringValue,
                      let new = edit["new_string"]?.stringValue
                else { continue }
                body += hunk(old: old, new: new)
            }
        case "Write":
            guard let content = call.input["content"]?.stringValue, !content.isEmpty else { return nil }
            body = hunk(old: "", new: content)
        default:
            return nil
        }

        guard !body.isEmpty else { return nil }
        return (["diff --git a/\(name) b/\(name)"] + body).joined(separator: "\n")
    }

    /// One replacement, as a hunk. Every line is prefixed, so a line of the
    /// file that itself starts with `-` survives the round trip.
    private static func hunk(old: String, new: String) -> [String] {
        let oldLines = split(old)
        let newLines = split(new)
        guard !oldLines.isEmpty || !newLines.isEmpty else { return [] }
        return ["@@ -1,\(oldLines.count) +1,\(newLines.count) @@"]
            + oldLines.prefix(ceiling).map { "-" + $0 }
            + newLines.prefix(ceiling).map { "+" + $0 }
    }

    private static func split(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var lines = text.components(separatedBy: "\n")
        // A trailing newline is a line ending, not an empty last line.
        if lines.count > 1, lines.last?.isEmpty == true { lines.removeLast() }
        return lines
    }

    /// A `Write` can be a thousand lines long, and every one of them would be
    /// parsed, coloured and laid out for a row nobody unfolds.
    private static let ceiling = 200
}

// MARK: - Measuring the result

/// What a call returned, cut down to what a row can draw.
@MainActor
struct ClaudeToolOutput {
    var preview: [String] = []
    var full = ""
    var lineCount = 0
    var isError = false
    /// How many lines the open row draws, which is not always all of them.
    var shownWhenOpen = 0

    init?(call: ClaudeToolCall) {
        guard let result = call.result?.trimmingCharacters(in: .whitespacesAndNewlines), !result.isEmpty
        else { return nil }
        let lines = result.split(separator: "\n", omittingEmptySubsequences: false)
        lineCount = lines.count
        isError = call.isError
        // An error is read in full and is rarely long; everything else is read
        // for its first few lines and then, if at all, for a screen of them.
        preview = lines.prefix(isError ? Self.errorLines : Self.previewLines).map(String.init)
        shownWhenOpen = min(lines.count, Self.openLines)
        full = lines.prefix(Self.openLines).joined(separator: "\n")
    }

    private static let previewLines = 3
    private static let errorLines = 6
    private static let openLines = 300
}
