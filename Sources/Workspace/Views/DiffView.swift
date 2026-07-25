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
    /// What a pull request adds to a diff: the comments already anchored to a
    /// line, and the means to write another. A working-tree diff leaves it nil
    /// and behaves exactly as it did before.
    var comments: DiffComments?

    /// Which files the user folded away. Kept here rather than inside a
    /// per-file view because the lazy stack throws away the state of anything
    /// it has scrolled past, which would silently unfold them again.
    @State private var collapsedFiles: Set<DiffFile.ID> = []
    /// The line whose "write a comment" box is open, if any.
    @State private var composing: DiffLineAnchor?
    /// The comment whose reply box is open, shared by every thread on screen so
    /// that opening one closes the last.
    @State private var replyingTo: PullRequestComment?
    /// The diff flattened to one entry per visible line — see `DiffElement`.
    /// Cached rather than recomputed in `body`, which also runs on every frame
    /// of a window resize.
    @State private var flattened = FlattenedDiff()

    /// A flattened diff, tagged with the parse it was built from. `body` runs
    /// as soon as a new diff arrives but `onChange` rebuilds only afterwards,
    /// and the entries index into `diff.files` — so the stale ones have to be
    /// recognised rather than rendered.
    private struct FlattenedDiff {
        var revision: UUID?
        var elements: [DiffElement] = []
    }

    private let cornerRadius: CGFloat = 8

    var body: some View {
        VStack(spacing: 0) {
            if showsControls {
                DiffLayoutBar(diff: diff, layout: $layout)
                Divider()
            }
            // Vertical scrolling only: the diff always fits the window width,
            // and long lines wrap inside their cell.
            GeometryReader { proxy in
                // Whole points only: a fractional width makes the split
                // columns land off the pixel grid.
                let width = max(proxy.size.width - 24, 320).rounded(.down)
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(flattened.revision == diff.revision ? flattened.elements : []) {
                            card($0, width: width)
                        }
                    }
                    .padding(12)
                    .frame(minHeight: proxy.size.height, alignment: .topLeading)
                }
                .background(Color(nsColor: AppColors.viewerBackground))
            }
        }
        .onChange(of: diff.revision, initial: true) { rebuild() }
        .onChange(of: collapsedFiles) { rebuild() }
        .onChange(of: composing) { rebuild() }
        .onChange(of: comments?.threads ?? [:]) { rebuild() }
    }

    private func rebuild() {
        flattened = FlattenedDiff(
            revision: diff.revision,
            elements: DiffElement.flatten(
                diff,
                collapsed: collapsedFiles,
                anchored: Set((comments?.threads ?? [:]).keys),
                composing: composing
            )
        )
    }

    /// One line of a file's card: its content, the card fill behind it, and the
    /// slice of the card outline that belongs to this line.
    private func card(_ element: DiffElement, width: CGFloat) -> some View {
        content(element, width: width)
            .frame(width: width, alignment: .leading)
            .background(.quaternary.opacity(0.15))
            // Only the first and last line of a file are rounded; the border
            // shape is stretched past the other lines so that its corners and
            // its top and bottom edges fall outside the clip below, leaving
            // just the two sides.
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(.quaternary, lineWidth: 1)
                    .padding(.top, element.opensCard ? 0 : -cornerRadius)
                    .padding(.bottom, element.closesCard ? 0 : -cornerRadius)
            }
            .clipShape(
                UnevenRoundedRectangle(
                    topLeadingRadius: element.opensCard ? cornerRadius : 0,
                    bottomLeadingRadius: element.closesCard ? cornerRadius : 0,
                    bottomTrailingRadius: element.closesCard ? cornerRadius : 0,
                    topTrailingRadius: element.opensCard ? cornerRadius : 0
                )
            )
            // The gap between cards, which the stack itself can no longer add.
            .padding(.top, element.opensCard && element.file > 0 ? 8 : 0)
    }

    @ViewBuilder
    private func content(_ element: DiffElement, width: CGFloat) -> some View {
        let file = diff.files[element.file]
        switch element.kind {
        case .fileHeader:
            DiffFileHeader(
                file: file,
                isCollapsed: Binding(
                    get: { collapsedFiles.contains(file.id) },
                    set: { isCollapsed in
                        if isCollapsed {
                            collapsedFiles.insert(file.id)
                        } else {
                            collapsedFiles.remove(file.id)
                        }
                    }
                )
            )
        case .binary:
            Text("Binary file")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(10)
        case .hunkHeader:
            Text(file.hunks[element.hunk].header)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(.blue.opacity(0.08))
        case .row:
            let row = file.hunks[element.hunk].rows[element.row]
            if layout == .split {
                SplitDiffRow(row: row, width: width, onComment: commentAction(file: file, row: row))
            } else {
                UnifiedDiffRows(row: row, width: width, onComment: commentAction(file: file, row: row))
            }
        case .comments:
            let row = file.hunks[element.hunk].rows[element.row]
            DiffCommentThreads(
                threads: threads(file: file, row: row),
                isPosting: comments?.isPosting ?? false,
                replyingTo: $replyingTo,
                onReply: { parent, body in await comments?.reply(parent, body) }
            )
            .frame(width: width, alignment: .leading)
        case .composer:
            if let anchor = composing {
                DiffCommentComposer(
                    anchor: anchor,
                    isPosting: comments?.isPosting ?? false,
                    onCancel: { composing = nil },
                    onSend: { body in
                        await comments?.add(anchor, body)
                        composing = nil
                    }
                )
                .frame(width: width, alignment: .leading)
            }
        }
    }

    /// Opens the box for a new comment, or nil when this diff takes none.
    private func commentAction(
        file: DiffFile,
        row: DiffRow
    ) -> ((PullRequestComment.Side) -> Void)? {
        guard comments != nil else { return nil }
        return { side in
            guard let anchor = row.anchor(in: file, side: side) else { return }
            composing = composing == anchor ? nil : anchor
            replyingTo = nil
        }
    }

    /// Every thread hanging off this row, both columns together.
    private func threads(file: DiffFile, row: DiffRow) -> [PullRequestCommentNode] {
        guard let index = comments?.threads else { return [] }
        return row.anchors(in: file).flatMap { index[$0] ?? [] }
    }
}

/// The comment side of a diff: what is already there, and what can be added.
///
/// Bundled into one optional so that a working-tree diff — which has no pull
/// request behind it — simply passes nothing.
struct DiffComments {
    /// Thread roots keyed by the line they are anchored to.
    var threads: [DiffLineAnchor: [PullRequestCommentNode]]
    var isPosting: Bool
    /// Starts a new thread on a line.
    var add: (DiffLineAnchor, String) async -> Void
    /// Replies to a comment in an existing thread.
    var reply: (PullRequestComment, String) async -> Void
}

extension DiffRow {
    /// Where this row sits in the file, per column. A context line exists in
    /// both, a removed line only in the old one, an added line only in the new.
    func anchor(in file: DiffFile, side: PullRequestComment.Side) -> DiffLineAnchor? {
        switch side {
        case .old:
            guard let oldNumber else { return nil }
            return DiffLineAnchor(path: file.oldPath, line: oldNumber, side: .old)
        case .new:
            guard let newNumber else { return nil }
            return DiffLineAnchor(path: file.newPath, line: newNumber, side: .new)
        }
    }

    /// Every key a comment on this row could have been filed under. A renamed
    /// file gets both names on the old side: Bitbucket reports one path for the
    /// whole comment, and it is the new one even for a line of the old file.
    func anchors(in file: DiffFile) -> [DiffLineAnchor] {
        var anchors: [DiffLineAnchor] = []
        if let oldNumber {
            anchors.append(DiffLineAnchor(path: file.oldPath, line: oldNumber, side: .old))
            if file.newPath != file.oldPath {
                anchors.append(DiffLineAnchor(path: file.newPath, line: oldNumber, side: .old))
            }
        }
        if let newNumber {
            anchors.append(DiffLineAnchor(path: file.newPath, line: newNumber, side: .new))
        }
        return anchors
    }
}

/// One line of the flattened diff.
///
/// `LazyVStack` only skips work for its own direct children. While every file
/// was a view of its own, the stack skipped *files* but built every row of a
/// file the instant its card came into view — on a pull request that touches a
/// thousand-line file, that is a thousand rows laid out in a single frame, and
/// the scroll visibly stalls. Flattening the tree makes every line — file
/// header, hunk header, code row — a child the stack can skip on its own.
///
/// Rows are addressed by index rather than carried along: copying the values
/// in here would duplicate the whole diff.
private struct DiffElement: Identifiable {
    enum Kind: UInt8 { case fileHeader, hunkHeader, row, binary, comments, composer }

    /// Tied to the position in the diff, not to the position in the flattened
    /// array, so folding a file away leaves the identity of everything below
    /// it alone.
    struct ID: Hashable {
        var kind: UInt8
        var file: Int32
        var hunk: Int32
        var row: Int32
    }

    var kind: Kind
    var file: Int
    var hunk: Int = -1
    var row: Int = -1
    /// The first and last line of a file, which carry the card's rounding.
    var opensCard = false
    var closesCard = false

    var id: ID {
        ID(kind: kind.rawValue, file: Int32(file), hunk: Int32(hunk), row: Int32(row))
    }

    /// `anchored` are the lines that already carry a thread, `composing` the one
    /// line whose new-comment box is open. Both get an extra element under the
    /// row they belong to, so the lazy stack can still skip them one by one.
    static func flatten(
        _ diff: Diff,
        collapsed: Set<DiffFile.ID>,
        anchored: Set<DiffLineAnchor> = [],
        composing: DiffLineAnchor? = nil
    ) -> [DiffElement] {
        var elements: [DiffElement] = []
        elements.reserveCapacity(diff.files.count + diff.addedLines + diff.removedLines)

        for (fileIndex, file) in diff.files.enumerated() {
            elements.append(DiffElement(kind: .fileHeader, file: fileIndex, opensCard: true))
            if !collapsed.contains(file.id) {
                if file.isBinary {
                    elements.append(DiffElement(kind: .binary, file: fileIndex))
                } else {
                    for (hunkIndex, hunk) in file.hunks.enumerated() {
                        elements.append(
                            DiffElement(kind: .hunkHeader, file: fileIndex, hunk: hunkIndex)
                        )
                        for (rowIndex, row) in hunk.rows.enumerated() {
                            elements.append(
                                DiffElement(
                                    kind: .row,
                                    file: fileIndex,
                                    hunk: hunkIndex,
                                    row: rowIndex
                                )
                            )
                            // Skip the lookup entirely for a diff with no
                            // comments, which is every working-tree diff.
                            guard !anchored.isEmpty || composing != nil else { continue }
                            let rowAnchors = row.anchors(in: file)
                            if rowAnchors.contains(where: anchored.contains) {
                                elements.append(
                                    DiffElement(
                                        kind: .comments,
                                        file: fileIndex,
                                        hunk: hunkIndex,
                                        row: rowIndex
                                    )
                                )
                            }
                            if let composing, rowAnchors.contains(composing) {
                                elements.append(
                                    DiffElement(
                                        kind: .composer,
                                        file: fileIndex,
                                        hunk: hunkIndex,
                                        row: rowIndex
                                    )
                                )
                            }
                        }
                    }
                }
            }
            elements[elements.count - 1].closesCard = true
        }
        return elements
    }
}

/// Split / unified switch plus the totals for this diff.
struct DiffLayoutBar: View {
    @Environment(WorkspaceStore.self) private var store
    let diff: Diff
    @Binding var layout: ViewerItem.DiffLayout

    var body: some View {
        HStack(spacing: 10) {
            DiffLayoutPicker(layout: $layout)

            Text("\(diff.files.count) \(diff.files.count == 1 ? "file" : "files")")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let project = projectOfSingleFileDiff {
                Button {
                    store.openAllChanges(project: project)
                } label: {
                    Label("View All Changes", systemImage: "plusminus.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .pointerCursor()
                .help("Show one diff with every change in the working tree")
            }

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

    /// The repository this diff belongs to, but only while a single file is on
    /// screen — the combined diff has an empty path and needs no such button.
    private var projectOfSingleFileDiff: Project? {
        guard case .workingDiff(let projectID, let path, _) = store.current?.kind,
              !path.isEmpty else { return nil }
        return store.project(withID: projectID)
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
        .pickerStyle(.menu)
        .labelsHidden()
        // Its own width, so the file count sits against the box instead of
        // across a gap. The cost is that "Unified" is wider than "Split", so
        // what follows shifts a little when the layout changes — cheaper than
        // a permanent hole in the bar.
        .fixedSize()
        .controlSize(.small)
        .pointerCursor()
        .help("Show the diff unified or side by side")
    }
}

/// The top line of a file's card, and the fold control for the whole file.
struct DiffFileHeader: View {
    let file: DiffFile
    @Binding var isCollapsed: Bool

    var body: some View {
        Button {
            isCollapsed.toggle()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                    // Only the chevron animates: folding a large file adds or
                    // removes thousands of rows, and animating that is exactly
                    // the work the lazy stack exists to avoid.
                    .animation(.easeInOut(duration: 0.15), value: isCollapsed)
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
            .frame(maxWidth: .infinity, alignment: .leading)
            // The whole strip is the hit area, not just the text in it.
            .contentShape(Rectangle())
            .background(.quaternary.opacity(0.3))
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .help(isCollapsed ? "Show the changes in this file" : "Hide the changes in this file")
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

/// One row shown as old | new. Both cells span the full row height, so the
/// divider forms a straight line and backgrounds fill the whole band.
struct SplitDiffRow: View {
    let row: DiffRow
    /// Width of the whole row; the two columns split it between them.
    let width: CGFloat
    /// Opens a comment on the column that was clicked. Nil on a diff that takes
    /// no comments.
    var onComment: ((PullRequestComment.Side) -> Void)?

    @State private var hovered: PullRequestComment.Side?

    private var oldWidth: CGFloat { (width / 2).rounded(.down) }
    private var newWidth: CGFloat { width - oldWidth }

    var body: some View {
        // `fixedSize` pins the row to its natural height so both cells stretch
        // to exactly that; left to themselves the two cells size and round
        // independently, which leaves a hairline of card background between
        // consecutive coloured bands. The unified layout has one cell per row
        // and so never showed it.
        HStack(alignment: .top, spacing: 0) {
            cell(
                number: row.oldNumber,
                text: row.oldHighlighted ?? AttributedString(row.oldText ?? ""),
                side: .old,
                width: oldWidth
            )
            cell(
                number: row.newNumber,
                text: row.newHighlighted ?? AttributedString(row.newText ?? ""),
                side: .new,
                width: newWidth
            )
        }
        .fixedSize(horizontal: false, vertical: true)
        // Drawn over the seam rather than stacked between the cells: a
        // `Divider` in the row would take part in the height calculation.
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(.quaternary)
                .frame(width: 1)
                .offset(x: oldWidth)
        }
    }

    private typealias Side = PullRequestComment.Side

    @ViewBuilder
    private func cell(
        number: Int?,
        text: AttributedString,
        side: Side,
        width: CGFloat
    ) -> some View {
        HStack(alignment: .top, spacing: 8) {
            // The number doubles as the comment button while the pointer is
            // over this column, so the row keeps its width either way.
            Text(number.map { "\($0)" } ?? "")
                .frame(width: 42, alignment: .trailing)
                .foregroundStyle(.tertiary)
                .overlay(alignment: .leading) {
                    if let onComment, number != nil, hovered == side {
                        AddCommentButton { onComment(side) }
                    }
                }
            Text(text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .font(.system(.caption, design: .monospaced))
        .padding(.horizontal, 8)
        .padding(.vertical, 1)
        .frame(width: width, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(background(for: side))
        .onHover { isInside in
            guard onComment != nil else { return }
            hovered = isInside ? side : (hovered == side ? nil : hovered)
        }
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
    var onComment: ((PullRequestComment.Side) -> Void)?

    @State private var hovered: PullRequestComment.Side?

    private var oldText: AttributedString { row.oldHighlighted ?? AttributedString(row.oldText ?? "") }
    private var newText: AttributedString { row.newHighlighted ?? AttributedString(row.newText ?? "") }

    var body: some View {
        VStack(spacing: 0) {
            switch row.kind {
            case .context:
                // A context line exists in both files; comment on the new one,
                // which is what the reviewer is looking at.
                line(marker: " ", number: row.oldNumber, text: oldText, color: .clear, side: .new)
            case .removed:
                line(marker: "−", number: row.oldNumber, text: oldText, color: .red.opacity(0.16), side: .old)
            case .added:
                line(marker: "+", number: row.newNumber, text: newText, color: .green.opacity(0.16), side: .new)
            case .changed:
                line(marker: "−", number: row.oldNumber, text: oldText, color: .red.opacity(0.16), side: .old)
                line(marker: "+", number: row.newNumber, text: newText, color: .green.opacity(0.16), side: .new)
            }
        }
    }

    private func line(
        marker: String,
        number: Int?,
        text: AttributedString,
        color: Color,
        side: PullRequestComment.Side
    ) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(number.map { "\($0)" } ?? "")
                .frame(width: 42, alignment: .trailing)
                .foregroundStyle(.tertiary)
                .overlay(alignment: .leading) {
                    if let onComment, number != nil, hovered == side {
                        AddCommentButton { onComment(side) }
                    }
                }
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
        .onHover { isInside in
            guard onComment != nil else { return }
            hovered = isInside ? side : (hovered == side ? nil : hovered)
        }
    }
}

/// The small "+" that appears in the gutter of the line under the pointer.
struct AddCommentButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus.bubble.fill")
                .font(.caption2)
                .foregroundStyle(.white)
                .frame(width: 16, height: 16)
                .background(.tint, in: RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .help("Comment on this line")
    }
}
