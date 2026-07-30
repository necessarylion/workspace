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
    /// Whether the file index is on screen. Left nil, this follows the
    /// window-wide preference; a commit passes its own, which starts hidden.
    var showsFiles: Binding<Bool>?
    /// What a pull request adds to a diff: the comments already anchored to a
    /// line, and the means to write another. A working-tree diff leaves it nil
    /// and behaves exactly as it did before.
    var comments: DiffComments?

    /// Which files the user folded away. Kept here rather than inside a
    /// per-file view because the lazy stack throws away the state of anything
    /// it has scrolled past, which would silently unfold them again.
    @State private var collapsedFiles: Set<DiffFile.ID> = []
    /// Deleted files already folded away by ``foldDeletions()``, which is not
    /// the same question as which files are folded *now*: a diff reloads under
    /// the reader — a file watcher, a new push — and re-seeding on every parse
    /// would fold a deletion they had just opened straight back up. A file is
    /// answered once, the first parse it appears in.
    @State private var foldedDeletions: Set<DiffFile.ID> = []
    /// The line whose "write a comment" box is open, if any.
    @State private var composing: DiffLineAnchor?
    /// The comment whose reply box is open, shared by every thread on screen so
    /// that opening one closes the last.
    @State private var replyingTo: PullRequestComment?
    /// The comment being rewritten, shared the same way for the same reason.
    @State private var editing: PullRequestComment?
    /// The diff flattened to one entry per visible line — see `DiffElement`.
    /// Cached rather than recomputed in `body`, which also runs on every frame
    /// of a window resize.
    @State private var flattened = FlattenedDiff()
    /// Files of a file-by-file diff that have been syntax-coloured, keyed by
    /// path — see `Diff.fileByFileThreshold`. One file is coloured each time
    /// the reader opens it, and kept in case they come back to it.
    @State private var colouredFiles: [DiffFile.ID: DiffFile] = [:]
    /// The parse `colouredFiles` was built from; anything older is thrown away.
    @State private var colouredRevision: UUID?
    /// Set the moment the whole body is about to say something else — a
    /// different file picked out of the index, or the same one shown split
    /// instead of unified — and cleared on the pass after, which is what gives
    /// what arrives something to fade up from. It is one opacity on the whole
    /// scrolling body: the rows are never animated, because a large diff has
    /// thousands of them and the thing that changed is the pane, not the lines.
    @State private var isSwappingBody = false

    /// A flattened diff, together with the parse it was built from.
    ///
    /// **Carrying the parse is what keeps the scroll position.** `body` runs as
    /// soon as a new diff arrives but `onChange` rebuilds only afterwards, and
    /// the entries are indices into `files` — so for that one frame the old
    /// elements cannot be read against the new parse. Rendering nothing instead
    /// was the obvious way out and a bad one: an empty stack collapses the
    /// scroll view's content to the height of the viewport, AppKit clamps the
    /// offset to the top, and the rows coming back a frame later cannot undo it.
    /// That is the whole of "a diff that reloaded under me jumped to the top",
    /// and with a file watcher reloading diffs by itself it stopped being rare.
    ///
    /// Holding the parse costs a retain rather than a copy — `Diff` is a struct
    /// of arrays — and makes the stale elements safe to draw, so the stack never
    /// empties and the offset is never clamped.
    private struct FlattenedDiff {
        var revision: UUID?
        /// What ``elements`` index into. Nil only before the first rebuild.
        var source: Diff?
        var elements: [DiffElement] = []
    }

    private let cornerRadius: CGFloat = 8

    /// The file index is only worth its width when there is more than one file
    /// to choose between. A file-by-file diff always keeps it: with no
    /// whole-diff view left, the index is the only way between its files.
    private var showsFileList: Bool {
        guard diff.files.count > 1 else { return false }
        return diff.isFileByFile || (showsFiles?.wrappedValue ?? store.showsDiffFiles)
    }

    /// The selection, ignored once the file it named is gone — a diff reloads
    /// while it is on screen, and a pull request can lose a file between two
    /// pushes. Nil shows every file, which a diff of many files never does: it
    /// falls back to its first file instead.
    private var currentFile: DiffFile.ID? {
        if let selectedFile, diff.files.contains(where: { $0.id == selectedFile }) {
            return selectedFile
        }
        return diff.isFileByFile ? diff.files.first?.id : nil
    }

    var body: some View {
        HStack(spacing: 0) {
            if showsFileList {
                DiffFileList(diff: diff, selection: $selectedFile)
                    .transition(ViewerMotion.contentArrival)
                Divider()
                    .transition(ViewerMotion.contentArrival)
            }
            diffBody
                // Left out of the transaction on purpose. The index is 232
                // points wide and the body is whatever is left, so putting that
                // width on a curve means laying out every row on screen on
                // every frame of it — the index fades, and the body snaps to
                // its new width at once underneath.
                .animation(nil, value: showsFileList)
        }
        // Scoped to whether the index is there, so it is the only thing this
        // row ever animates.
        .animation(ViewerMotion.contentChange, value: showsFileList)
        .onChange(of: diff.revision, initial: true) { rebuild(collapsed: foldDeletions()) }
        .onChange(of: collapsedFiles) { rebuild() }
        .onChange(of: composing) { rebuild() }
        .onChange(of: currentFile) {
            rebuild()
            // The fade is the whole of the motion here, so Reduce Motion means
            // no fade rather than a shorter one — the file simply changes.
            if !ViewerMotion.isReduced { isSwappingBody = true }
        }
        // Split and unified are the same lines drawn a different way round, and
        // the switch between them was a hard cut of the entire body. It takes
        // the same two steps a picked file does rather than an animation of its
        // own: the rows are the one thing here that must never be in one.
        .onChange(of: layout) {
            if !ViewerMotion.isReduced { isSwappingBody = true }
        }
        // The lines that carry a thread, not the threads themselves: flattening
        // only asks which lines to leave room under, and comparing the comment
        // trees instead walked every reply on this pull request each time the
        // window was resized.
        .onChange(of: anchoredLines) { rebuild() }
    }

    /// The lines a thread hangs off, which is all the flattening needs to know.
    private var anchoredLines: Set<DiffLineAnchor> {
        guard let threads = comments?.threads else { return [] }
        return Set(threads.keys)
    }

    private var diffBody: some View {
        VStack(spacing: 0) {
            if showsControls {
                DiffLayoutBar(
                    diff: diff,
                    layout: $layout,
                    selectedFile: $selectedFile,
                    showsFiles: showsFiles
                )
                Divider()
            }
            // Vertical scrolling only: the diff always fits the window width,
            // and long lines wrap inside their cell.
            GeometryReader { proxy in
                // Whole points only: a fractional width makes the split
                // columns land off the pixel grid.
                let width = max(proxy.size.width - 24, 320).rounded(.down)
                // Resolved once for the whole diff rather than inside each
                // cell: the lookup goes through `NSFont(name:size:)`, and a
                // screenful of split rows asks for it a hundred times a frame.
                let font = AppearanceSettings.shared.diffFont
                ScrollViewReader { scroll in
                    ScrollView(.vertical) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            // Unconditional, and deliberately so — see
                            // `FlattenedDiff`. The elements are read against the
                            // parse they were built from, so the frame between a
                            // new diff arriving and `rebuild()` running draws the
                            // old rows rather than none of them.
                            ForEach(flattened.elements) {
                                card($0, width: width, font: font)
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
            // Picking a file replaces every row under an offset that is about
            // to be thrown to the top anyway, which read as a flicker; changing
            // the layout redraws every one of them in a different shape. Two
            // steps, because there is no transition to hang either on: the body
            // is drawn at nothing on the pass that carries the change, and the
            // pass after brings it up. The index beside it and the bar above
            // are outside this, so the only thing that moves is the part that
            // changed.
            .opacity(isSwappingBody ? 0 : 1)
            .task(id: isSwappingBody) {
                guard isSwappingBody else { return }
                withAnimation(ViewerMotion.contentChange) { isSwappingBody = false }
            }
        }
    }

    /// Folds away every file this diff deletes, and returns the folded set.
    ///
    /// A deletion is the one file nobody reads: the whole of the old file,
    /// every line removed, with nothing on the other side to compare it
    /// against — and a branch that drops a directory buries the files that were
    /// actually changed under thousands of them. The header stays, so the count
    /// is still there and one click still opens it.
    ///
    /// Left alone for a diff of a single file, which is a file somebody asked
    /// for by name: there is nothing to scroll past, and folding it would show
    /// them an empty pane.
    ///
    /// The set is returned rather than read back out of ``collapsedFiles``
    /// because the caller rebuilds in the same pass, and a `@State` written
    /// here is only readable on the next.
    private func foldDeletions() -> Set<DiffFile.ID> {
        guard diff.files.count > 1 else { return collapsedFiles }
        var collapsed = collapsedFiles
        for file in diff.files where file.change == .deleted {
            guard foldedDeletions.insert(file.id).inserted else { continue }
            collapsed.insert(file.id)
        }
        if collapsed != collapsedFiles { collapsedFiles = collapsed }
        return collapsed
    }

    /// `collapsed` stands in for ``collapsedFiles``, for the one caller that
    /// folds a file in the same pass it rebuilds in — see ``foldDeletions()``.
    private func rebuild(collapsed: Set<DiffFile.ID>? = nil) {
        if diff.isFileByFile {
            // The list has to agree with what is drawn, or a diff that fell
            // back to its first file would show no selection at all.
            if selectedFile != currentFile { selectedFile = currentFile }
            colourCurrentFile()
        }
        flattened = FlattenedDiff(
            revision: diff.revision,
            source: diff,
            elements: DiffElement.flatten(
                diff,
                only: currentFile,
                collapsed: collapsed ?? collapsedFiles,
                anchored: anchoredLines,
                composing: composing
            )
        )
    }

    /// Colours the file on screen, for a diff `DiffHighlighter` left plain
    /// because it holds too many files to colour at once.
    private func colourCurrentFile() {
        if colouredRevision != diff.revision {
            colouredFiles.removeAll()
            colouredRevision = diff.revision
        }
        guard let currentFile, colouredFiles[currentFile] == nil,
              let file = diff.files.first(where: { $0.id == currentFile }) else { return }
        colouredFiles[currentFile] = DiffHighlighter.highlight(file)
    }

    /// The file to draw, which for a file-by-file diff is the coloured copy
    /// once there is one — the parse itself holds the plain files.
    ///
    /// Read from the parse the elements were flattened against rather than from
    /// `diff`, which is what lets a row outlive by one frame the diff it came
    /// from. `flattened.source` is nil only before the first rebuild, when there
    /// are no elements to ask about either.
    private func file(at index: Int) -> DiffFile {
        let source = flattened.source ?? diff
        let file = source.files[index]
        guard colouredRevision == source.revision else { return file }
        return colouredFiles[file.id] ?? file
    }

    /// One line of a file's card: its content, the card fill behind it, and the
    /// slice of the card outline that belongs to this line.
    ///
    /// Only the two lines that carry the rounding are drawn with a shape: a
    /// stroked rectangle clipped to a rounded one costs a mask layer per line,
    /// and a file of a thousand lines is a thousand of them for a corner that
    /// appears twice. Every line in between gets the two hairlines it actually
    /// shows.
    @ViewBuilder
    private func card(_ element: DiffElement, width: CGFloat, font: Font) -> some View {
        let line = content(element, width: width, font: font)
            .frame(width: width, alignment: .leading)
            .background(.quaternary.opacity(0.15))
        if element.opensCard || element.closesCard {
            // The border shape is stretched past the edge the card does not end
            // at, so that its corners and that edge fall outside the clip and
            // meet the plain sides of the line next to it.
            line
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
        } else {
            line
                .overlay(alignment: .leading) { cardEdge }
                .overlay(alignment: .trailing) { cardEdge }
        }
    }

    /// One side of the card outline, for the lines between its ends.
    private var cardEdge: some View {
        Rectangle().fill(.quaternary).frame(width: 1)
    }

    @ViewBuilder
    private func content(_ element: DiffElement, width: CGFloat, font: Font) -> some View {
        let file = file(at: element.file)
        switch element.kind {
        case .fileHeader:
            DiffFileHeader(
                path: file.displayPath,
                change: file.change,
                addedLines: file.addedLines,
                removedLines: file.removedLines,
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
                .font(font)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(.blue.opacity(0.08))
        case .row:
            let row = file.hunks[element.hunk].rows[element.row]
            if layout == .split {
                SplitDiffRow(
                    row: row,
                    width: width,
                    font: font,
                    onComment: commentAction(file: file, row: row)
                )
            } else {
                UnifiedDiffRows(
                    row: row,
                    width: width,
                    font: font,
                    onComment: commentAction(file: file, row: row)
                )
            }
        case .comments:
            let row = file.hunks[element.hunk].rows[element.row]
            DiffCommentThreads(
                threads: threads(file: file, row: row),
                isPosting: comments?.isPosting ?? false,
                replyingTo: $replyingTo,
                editing: $editing,
                mentions: comments?.mentions ?? .none,
                onReply: { parent, body in await comments?.reply(parent, body) },
                // Flattened: chaining through an optional bundle onto an
                // optional closure would otherwise nest one inside the other.
                onResolve: comments?.resolve ?? nil,
                onEdit: comments?.edit ?? nil,
                onDelete: comments?.delete ?? nil
            )
            .frame(width: width, alignment: .leading)
        case .composer:
            if let anchor = composing {
                DiffCommentComposer(
                    anchor: anchor,
                    isPosting: comments?.isPosting ?? false,
                    mentions: comments?.mentions ?? .none,
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
            editing = nil
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
    /// Who an `@` in one of these boxes can name.
    var mentions: MentionSource = .none
    /// Starts a new thread on a line.
    var add: (DiffLineAnchor, String) async -> Void
    /// Replies to a comment in an existing thread.
    var reply: (PullRequestComment, String) async -> Void
    /// Settles a thread, or opens it again. Nil for a diff that has no host
    /// behind it to be told.
    var resolve: ((PullRequestComment, Bool) async -> Void)?
    /// Replaces what a comment says. Nil for the same reason.
    var edit: ((PullRequestComment, String) async -> Void)?
    /// Takes a comment down. Nil for the same reason.
    var delete: ((PullRequestComment) async -> Void)?
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
        // Every row, not just the changed ones: counting only the +/- totals
        // left the context lines to grow the array, which for a long diff means
        // copying a list of tens of thousands of entries several times over.
        let rows = diff.files.reduce(0) { total, file in
            total + file.hunks.reduce(1) { $0 + $1.rows.count + 1 }
        }
        elements.reserveCapacity(rows)

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
    /// Nil follows the window-wide preference — see `DiffView.showsFiles`.
    var showsFiles: Binding<Bool>?

    var body: some View {
        @Bindable var store = store
        let filesShown = showsFiles ?? $store.showsDiffFiles
        return HStack(spacing: 10) {
            // A file-by-file diff keeps its index open — there is no whole-diff
            // view to fall back on, so hiding it would strand the reader.
            if diff.files.count > 1 && !diff.isFileByFile {
                Toggle(isOn: filesShown) {
                    Image(systemName: "sidebar.left")
                }
                .toggleStyle(.button)
                .controlSize(.small)
                .help(filesShown.wrappedValue ? "Hide the file list" : "Show the file list")
                .pointerCursor()
            }

            DiffLayoutPicker(layout: $layout)

            // While one file is on screen, its name says more than the total.
            if let file = diff.files.first(where: { $0.id == selectedFile }) {
                Text("1 of \(diff.files.count) files")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if diff.isFileByFile {
                    // Nothing to go back to: past the threshold the whole diff
                    // is never built, so "Show All" would have to load it.
                    Text("one at a time")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .help(
                            """
                            More than \(Diff.fileByFileThreshold) files changed, \
                            so they load one at a time — pick another in the list.
                            """
                        )
                } else {
                    Button("Show All") { selectedFile = nil }
                        .buttonStyle(.link)
                        .font(.caption)
                        .help("Show every file in this diff again")
                        .pointerCursor()
                        .accessibilityLabel("Show all files, currently showing \(file.displayPath)")
                }
            } else {
                Text("\(diff.files.count) \(diff.files.count == 1 ? "file" : "files")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let project = projectOfSingleFileDiff {
                // Off past the threshold: a combined diff of that many files is
                // exactly what the file-by-file rule exists to avoid building.
                let changed = project.gitStatus?.changes.count ?? 0
                let tooMany = changed > Diff.fileByFileThreshold
                Button {
                    store.openAllChanges(project: project)
                } label: {
                    Label("View All Changes", systemImage: "plusminus.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(tooMany)
                .help(
                    tooMany
                        ? """
                          \(changed) files have changed — more than \
                          \(Diff.fileByFileThreshold), so they are read one at a time
                          """
                        : "Show one diff with every change in the working tree"
                )
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
        // The pane's own colour under the material, which is what the material
        // was blending with anyway — the diff sits on it everywhere it is
        // drawn, so this changes nothing at rest. What it buys is a bar that is
        // opaque *while it arrives*: without it this strip is the one part of
        // the diff a tab being left can still be read through.
        .background(Color(nsColor: AppColors.viewerBackground))
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
                // Past the threshold there is no whole diff to go back to, so
                // the header is a count rather than a way in.
                if diff.isFileByFile {
                    HStack(spacing: 6) {
                        Text("\(diff.files.count) Files")
                        Spacer(minLength: 4)
                        Text("one at a time").foregroundStyle(.secondary)
                    }
                    .font(.caption)
                    .padding(.trailing, 6)
                } else {
                    allFiles
                }
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
    var changeSymbol: String { change.symbol }
    var changeColor: Color { change.color }
}

extension DiffFile.Change {
    var symbol: String {
        switch self {
        case .added: "plus.square.fill"
        case .deleted: "minus.square.fill"
        case .renamed: "arrow.right.square.fill"
        case .modified: "square.fill.on.square.fill"
        }
    }

    var color: Color {
        switch self {
        case .added: .green
        case .deleted: .red
        case .renamed: .blue
        case .modified: .orange
        }
    }
}

/// The top line of a file's card, and the fold control for the whole file.
///
/// Takes the few things it draws rather than the `DiffFile` they come from: it
/// is a direct child of the lazy stack, and holding the file would have SwiftUI
/// compare every hunk of it to decide whether this one strip had changed.
struct DiffFileHeader: View {
    let path: String
    let change: DiffFile.Change
    let addedLines: Int
    let removedLines: Int
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
                Image(systemName: change.symbol)
                    .foregroundStyle(change.color)
                Text(path)
                    .font(.system(.callout, design: .monospaced).weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer()
                Text("+\(addedLines)")
                    .foregroundStyle(.green)
                Text("−\(removedLines)")
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
    /// Resolved by the diff, not per cell — see `DiffView.diffBody`.
    let font: Font
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
        .font(font)
        .padding(.horizontal, 8)
        .padding(.vertical, 1)
        .frame(width: width, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(background(for: side))
        .onHover(if: onComment != nil) { isInside in
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
    /// Resolved by the diff, not per line — see `DiffView.diffBody`.
    let font: Font
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
        .font(font)
        .padding(.horizontal, 8)
        .padding(.vertical, 1)
        .frame(width: width, alignment: .leading)
        .background(color)
        .onHover(if: onComment != nil) { isInside in
            hovered = isInside ? side : (hovered == side ? nil : hovered)
        }
    }
}

private extension View {
    /// `onHover`, but only where the pointer has something to do.
    ///
    /// A working-tree diff takes no comments, so nothing on a row reacts to the
    /// pointer — and a tracking region per column per line is work the scroll
    /// pays for on every frame of a file the size of a real one.
    @ViewBuilder
    func onHover(if enabled: Bool, perform: @escaping (Bool) -> Void) -> some View {
        if enabled {
            onHover(perform: perform)
        } else {
            self
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
