import SwiftUI

/// Side-by-side (or unified) rendering of a parsed diff.
///
/// The layout switch belongs to the diff itself, not to the window toolbar —
/// it only makes sense while a diff is on screen.
struct DiffView: View {
    let diff: Diff
    @Binding var layout: ViewerItem.DiffLayout
    /// The pull request view puts the switch in its own bar instead.
    var showsControls = true

    var body: some View {
        VStack(spacing: 0) {
            if showsControls {
                DiffLayoutBar(diff: diff, layout: $layout)
                Divider()
            }
            // Vertical scrolling only: the diff always fits the window width,
            // and long lines wrap inside their cell.
            GeometryReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(diff.files) { file in
                            DiffFileView(
                                file: file,
                                layout: layout,
                                availableWidth: max(proxy.size.width - 24, 320)
                            )
                        }
                    }
                    .padding(12)
                    .frame(minHeight: proxy.size.height, alignment: .topLeading)
                }
                .background(Color(nsColor: .textBackgroundColor))
            }
        }
    }
}

/// Split / unified switch plus the totals for this diff.
struct DiffLayoutBar: View {
    let diff: Diff
    @Binding var layout: ViewerItem.DiffLayout

    var body: some View {
        HStack(spacing: 10) {
            DiffLayoutPicker(layout: $layout)

            Text("\(diff.files.count) \(diff.files.count == 1 ? "file" : "files")")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            Text("+\(diff.addedLines)")
                .foregroundStyle(.green)
            Text("−\(diff.removedLines)")
                .foregroundStyle(.red)
        }
        .font(.caption.monospacedDigit())
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }
}

struct DiffLayoutPicker: View {
    @Binding var layout: ViewerItem.DiffLayout

    var body: some View {
        Picker("Layout", selection: $layout) {
            ForEach(ViewerItem.DiffLayout.allCases) { option in
                Label(option.title, systemImage: option.icon).tag(option)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 150)
        .help("Show the diff unified or side by side")
    }
}

struct DiffFileView: View {
    let file: DiffFile
    let layout: ViewerItem.DiffLayout
    let availableWidth: CGFloat

    /// The card always spans the full viewport; in split view each column is
    /// exactly half, so the divider is one straight line and both hosts render
    /// identically. Long lines wrap rather than scroll sideways.
    private var columnWidth: CGFloat {
        (availableWidth - 1) / 2
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if file.isBinary {
                Text("Binary file")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(10)
            } else {
                ForEach(file.hunks) { hunk in
                    hunkHeader(hunk)
                    ForEach(hunk.rows) { row in
                        if layout == .split {
                            SplitDiffRow(row: row, columnWidth: columnWidth)
                        } else {
                            UnifiedDiffRows(row: row, width: availableWidth)
                        }
                    }
                }
            }
        }
        .frame(width: availableWidth, alignment: .leading)
        .background(.quaternary.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8).stroke(.quaternary, lineWidth: 1)
        )
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: changeSymbol)
                .foregroundStyle(changeColor)
            Text(file.displayPath)
                .font(.system(.callout, design: .monospaced).weight(.medium))
                .lineLimit(1)
                .truncationMode(.head)
            Spacer()
            Text("+\(file.addedLines)")
                .foregroundStyle(.green)
            Text("−\(file.removedLines)")
                .foregroundStyle(.red)
        }
        .font(.caption.monospacedDigit())
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.quaternary.opacity(0.3))
    }

    private func hunkHeader(_ hunk: DiffHunk) -> some View {
        Text(hunk.header)
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(.blue.opacity(0.08))
    }

    private var changeSymbol: String {
        switch file.change {
        case .added: "plus.square.fill"
        case .deleted: "minus.square.fill"
        case .renamed: "arrow.right.square.fill"
        case .modified: "square.fill.on.square.fill"
        }
    }

    private var changeColor: Color {
        switch file.change {
        case .added: .green
        case .deleted: .red
        case .renamed: .blue
        case .modified: .orange
        }
    }
}

/// One row shown as old | new. Both cells share one fixed width, so the
/// divider forms a straight line and backgrounds fill the whole band.
struct SplitDiffRow: View {
    let row: DiffRow
    let columnWidth: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            cell(
                number: row.oldNumber,
                text: row.oldHighlighted ?? AttributedString(row.oldText ?? ""),
                side: .old
            )
            Divider()
            cell(
                number: row.newNumber,
                text: row.newHighlighted ?? AttributedString(row.newText ?? ""),
                side: .new
            )
        }
    }

    private enum Side { case old, new }

    @ViewBuilder
    private func cell(number: Int?, text: AttributedString, side: Side) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(number.map { "\($0)" } ?? "")
                .frame(width: 42, alignment: .trailing)
                .foregroundStyle(.tertiary)
            Text(text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .font(.system(.caption, design: .monospaced))
        .padding(.horizontal, 8)
        .padding(.vertical, 1)
        .frame(width: columnWidth, alignment: .leading)
        .background(background(for: side))
    }

    private func background(for side: Side) -> Color {
        switch row.kind {
        case .context:
            .clear
        case .added:
            side == .new ? .green.opacity(0.16) : .clear
        case .removed:
            side == .old ? .red.opacity(0.16) : .clear
        case .changed:
            side == .old ? .red.opacity(0.16) : .green.opacity(0.16)
        }
    }
}

/// Same row, stacked the way `git diff` prints it.
struct UnifiedDiffRows: View {
    let row: DiffRow
    let width: CGFloat

    private var oldText: AttributedString { row.oldHighlighted ?? AttributedString(row.oldText ?? "") }
    private var newText: AttributedString { row.newHighlighted ?? AttributedString(row.newText ?? "") }

    var body: some View {
        VStack(spacing: 0) {
            switch row.kind {
            case .context:
                line(marker: " ", number: row.oldNumber, text: oldText, color: .clear)
            case .removed:
                line(marker: "−", number: row.oldNumber, text: oldText, color: .red.opacity(0.16))
            case .added:
                line(marker: "+", number: row.newNumber, text: newText, color: .green.opacity(0.16))
            case .changed:
                line(marker: "−", number: row.oldNumber, text: oldText, color: .red.opacity(0.16))
                line(marker: "+", number: row.newNumber, text: newText, color: .green.opacity(0.16))
            }
        }
    }

    private func line(marker: String, number: Int?, text: AttributedString, color: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(number.map { "\($0)" } ?? "")
                .frame(width: 42, alignment: .trailing)
                .foregroundStyle(.tertiary)
            Text(marker)
                .foregroundStyle(.secondary)
            Text(text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .font(.system(.caption, design: .monospaced))
        .padding(.horizontal, 8)
        .padding(.vertical, 1)
        .frame(width: width, alignment: .leading)
        .background(color)
    }
}
