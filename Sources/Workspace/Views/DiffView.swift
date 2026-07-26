import SwiftUI

/// Side-by-side (or unified) rendering of a parsed diff.
///
/// The layout switch belongs to the diff itself, not to the window toolbar —
/// it only makes sense while a diff is on screen.
struct DiffView: View {
    @Environment(WorkspaceStore.self) private var store
    let diff: Diff
    @Binding var layout: ViewerItem.DiffLayout
    /// The file on screen, or nil for all of them.
    @Binding var selectedFile: DiffFile.ID?
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

    /// The file index is only worth its width when there is more than one file
    /// to choose between.
    private var showsFileList: Bool { diff.files.count > 1 && store.showsDiffFiles }

    /// The selection, ignored once the file it named is gone — a diff reloads
    /// while it is on screen, and a pull request can lose a file between two
    /// pushes.
    private var currentFile: DiffFile.ID? {
        guard let selectedFile, diff.files.contains(where: { $0.id == selectedFile }) else {
            return nil
        }
        return selectedFile
    }

    var body: some View {
        HStack(spacing: 0) {
            if showsFileList {
                DiffFileList(diff: diff, selection: $selectedFile)
                Divider()
            }
            diffBody
        }
        .onChange(of: diff.revision, initial: true) { rebuild() }
        .onChange(of: collapsedFiles) { rebuild() }
        .onChange(of: composing) { rebuild() }
        .onChange(of: currentFile) { rebuild() }
        .onChange(of: comments?.threads ?? [:]) { rebuild() }
    }

    private var diffBody: some View {
        VStack(spacing: 0) {
            if showsControls {
                DiffLayoutBar(diff: diff, layout: $layout, selectedFile: $selectedFile)
                Divider()
            }
            // Vertical scrolling only: the diff always fits the window width,
            // and long lines wrap inside their cell.
            GeometryReader { proxy in
                // Whole points only: a fractional width makes the split
                // columns land off the pixel grid.
                let width = max(proxy.size.width - 24, 320).rounded(.down)
                ScrollViewReader { scroll in
                    ScrollView(.vertical) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(flattened.revision == diff.revision ? flattened.elements : []) {
                                card($0, width: width)
                            }
                        }
                        .padding(12)
                        .frame(minHeight: proxy.size.height, alignment: .topLeading)
                    }
                    // Picking a file puts a different diff under an unchanged
                    // scroll offset; without this the new file opens partway
                    // down, or past its end entirely.
                    .onChange(of: currentFile) {
                        guard let first = flattened.elements.first else { return }
                        scroll.scrollTo(first.id, anchor: .top)
                    }
                }
                .background(Color(nsColor: AppColors.viewerBackground))
            }
        }
    }

    private func rebuild() {
        flattened = FlattenedDiff(
            revision: diff.revision,
            elements: DiffElement.flatten(
                diff,
                only: currentFile,
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

    /// `only` limits the result to a single file, which is how the file index
    /// beside the diff narrows it. `anchored` are the lines that already carry a
    /// thread, `composing` the one line whose new-comment box is open. Both get
    /// an extra element under the row they belong to, so the lazy stack can
    /// still skip them one by one.
    static func flatten(
        _ diff: Diff,
        only: DiffFile.ID? = nil,
        collapsed: Set<DiffFile.ID>,
        anchored: Set<DiffLineAnchor> = [],
        composing: DiffLineAnchor? = nil
    ) -> [DiffElement] {
        var elements: [DiffElement] = []
        elements.reserveCapacity(diff.files.count + diff.addedLines + diff.removedLines)

        for (fileIndex, file) in diff.files.enumerated() {
            // The indices still address `diff.files`, so skipping a file here
            // costs nothing but the rows it would have built.
            if let only, file.id != only { continue }
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
    @Binding var selectedFile: DiffFile.ID?

    var body: some View {
        @Bindable var store = store
        HStack(spacing: 10) {
            if diff.files.count > 1 {
                Toggle(isOn: $store.showsDiffFiles) {
                    Image(systemName: "sidebar.left")
                }
                .toggleStyle(.button)
                .controlSize(.small)
                .help(store.showsDiffFiles ? "Hide the file list" : "Show the file list")
                .pointerCursor()
            }

            DiffLayoutPicker(layout: $layout)

            // While one file is on screen, its name says more than the total.
            if let file = diff.files.first(where: { $0.id == selectedFile }) {
                Text("1 of \(diff.files.count) files")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Show All") { selectedFile = nil }
                    .buttonStyle(.link)
                    .font(.caption)
                    .help("Show every file in this diff again")
                    .pointerCursor()
                    .accessibilityLabel("Show all files, currently showing \(file.displayPath)")
            } else {
                Text("\(diff.files.count) \(diff.files.count == 1 ? "file" : "files")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let project = projectOfSingleFileDiff {
                Button {
                    store.openAllChanges(project: project)
                } label: {
                    Label("View All Changes", systemImage: "plusminus.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Show one diff with every change in the working tree")
                .pointerCursor()
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
        .help("Show the diff unified or side by side")
        .pointerCursor()
    }
}

/// The index down the side of a diff: every file it touches, and which one is
/// being read.
///
/// Selecting a file renders that file alone. A pull request that touches
/// seventeen files is seventeen files of rows in one scroll otherwise, and
/// there is no way back to the top of a file once past it.
struct DiffFileList: View {
    let diff: Diff
    @Binding var selection: DiffFile.ID?

    var body: some View {
        List(selection: $selection) {
            Section {
                ForEach(diff.files) { file in
                    row(file).tag(file.id)
                }
            } header: {
                allFiles
            }
        }
        .listStyle(.sidebar)
        .frame(width: 232)
        .environment(\.defaultMinListRowHeight, 24)
    }

    /// The way back to the whole diff, kept at the top of the list rather than
    /// hidden in the bar — it is the state the list starts in.
    private var allFiles: some View {
        Button {
            selection = nil
        } label: {
            HStack(spacing: 6) {
                Text("All Files")
                Spacer(minLength: 4)
                Text("\(diff.files.count)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .font(.caption.weight(selection == nil ? .semibold : .regular))
            .foregroundStyle(selection == nil ? Color.accentColor : .primary)
            // A section header runs closer to the edge than the rows under it,
            // which left the count against the divider.
            .padding(.trailing, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    private func row(_ file: DiffFile) -> some View {
        HStack(spacing: 6) {
            Image(systemName: file.changeSymbol)
                .font(.caption2)
                .foregroundStyle(file.changeColor)
            VStack(alignment: .leading, spacing: 0) {
                Text(name(of: file))
                    .lineLimit(1)
                    .truncationMode(.middle)
                // The folder only when there is one, and truncated from the
                // front: the end of a path is what tells two files apart.
                if let folder = folder(of: file) {
                    Text(folder)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            Spacer(minLength: 4)
            if file.addedLines > 0 {
                Text("+\(file.addedLines)").foregroundStyle(.green)
            }
            if file.removedLines > 0 {
                Text("−\(file.removedLines)").foregroundStyle(.red)
            }
        }
        .font(.caption.monospacedDigit())
        .help(file.displayPath)
    }

    private func name(of file: DiffFile) -> String {
        String(file.newPath.split(separator: "/").last ?? Substring(file.newPath))
    }

    private func folder(of file: DiffFile) -> String? {
        let parts = file.newPath.split(separator: "/").dropLast()
        return parts.isEmpty ? nil : parts.joined(separator: "/")
    }
}

extension DiffFile {
    var changeSymbol: String {
        switch change {
        case .added: "plus.square.fill"
        case .deleted: "minus.square.fill"
        case .renamed: "arrow.right.square.fill"
        case .modified: "square.fill.on.square.fill"
        }
    }

    var changeColor: Color {
        switch change {
        case .added: .green
        case .deleted: .red
        case .renamed: .blue
        case .modified: .orange
        }
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
                Image(systemName: file.changeSymbol)
                    .foregroundStyle(file.changeColor)
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
        .help(isCollapsed ? "Show the changes in this file" : "Hide the changes in this file")
        .pointerCursor()
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
            cell(number: row.oldNumber, text: text(for: .old), side: .old, width: oldWidth)
            cell(number: row.newNumber, text: text(for: .new), side: .new, width: newWidth)
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

    /// The column's text, with the words that differ from the other column
    /// picked out.
    private func text(for side: Side) -> AttributedString {
        switch side {
        case .old:
            (row.oldHighlighted ?? AttributedString(row.oldText ?? ""))
                .markingWords(row.oldWordRanges, with: DiffColors.removedWord)
        case .new:
            (row.newHighlighted ?? AttributedString(row.newText ?? ""))
                .markingWords(row.newWordRanges, with: DiffColors.addedWord)
        }
    }

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
            side == .new ? DiffColors.addedLine : .clear
        case .removed:
            side == .old ? DiffColors.removedLine : .clear
        case .changed:
            side == .old ? DiffColors.removedLine : DiffColors.addedLine
        }
    }
}

/// Same row, stacked the way `git diff` prints it.
struct UnifiedDiffRows: View {
    let row: DiffRow
    let width: CGFloat
    var onComment: ((PullRequestComment.Side) -> Void)?

    @State private var hovered: PullRequestComment.Side?

    private var oldText: AttributedString {
        (row.oldHighlighted ?? AttributedString(row.oldText ?? ""))
            .markingWords(row.oldWordRanges, with: DiffColors.removedWord)
    }

    private var newText: AttributedString {
        (row.newHighlighted ?? AttributedString(row.newText ?? ""))
            .markingWords(row.newWordRanges, with: DiffColors.addedWord)
    }

    var body: some View {
        VStack(spacing: 0) {
            switch row.kind {
            case .context:
                // A context line exists in both files; comment on the new one,
                // which is what the reviewer is looking at.
                line(marker: " ", number: row.oldNumber, text: oldText, color: .clear, side: .new)
            case .removed:
                line(marker: "−", number: row.oldNumber, text: oldText, color: DiffColors.removedLine, side: .old)
            case .added:
                line(marker: "+", number: row.newNumber, text: newText, color: DiffColors.addedLine, side: .new)
            case .changed:
                line(marker: "−", number: row.oldNumber, text: oldText, color: DiffColors.removedLine, side: .old)
                line(marker: "+", number: row.newNumber, text: newText, color: DiffColors.addedLine, side: .new)
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

/// The two tiers of diff colour.
///
/// A changed line gets the wash; the words inside it that actually differ get
/// the stronger block on top, the way GitHub and VS Code both show it. A line
/// that was purely added or removed has no counterpart to compare against and
/// keeps the wash alone.
///
/// The values are opaque and darker than the card behind them, rather than a
/// translucent bright red or green. A translucent wash lifts the background
/// towards the syntax colours sitting on it and leaves the code looking washed
/// out; going deeper instead buys contrast back, which is also how both editors
/// tint a diff on a dark theme.
enum DiffColors {
    static let addedLine = Color(red: 0.11, green: 0.20, blue: 0.14)
    static let addedWord = Color(red: 0.16, green: 0.36, blue: 0.22)
    static let removedLine = Color(red: 0.24, green: 0.12, blue: 0.13)
    static let removedWord = Color(red: 0.44, green: 0.17, blue: 0.18)
}

extension AttributedString {
    /// Paints `ranges` — offsets in characters — with a background colour,
    /// leaving the syntax colouring underneath untouched.
    func markingWords(_ ranges: [Range<Int>], with color: Color) -> AttributedString {
        guard !ranges.isEmpty else { return self }
        var result = self
        for range in ranges {
            // Re-read the view each time: the loop only changes attributes, but
            // the ranges come from the parser and the text from the highlighter,
            // so a mismatch has to fall through rather than trap.
            let characters = result.characters
            guard let lower = characters.index(
                    characters.startIndex,
                    offsetBy: range.lowerBound,
                    limitedBy: characters.endIndex
                  ),
                  let upper = characters.index(
                    lower,
                    offsetBy: range.count,
                    limitedBy: characters.endIndex
                  ),
                  lower < upper
            else { continue }
            result[lower..<upper].backgroundColor = color
        }
        return result
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
        .help("Comment on this line")
        .pointerCursor()
    }
}
