import AppKit
import SwiftUI

/// ⌘P — the whole repository in one list, narrowed as you type, ⏎ to open.
///
/// It floats over the window on glass rather than opening a pane: you are on
/// your way somewhere, and everything behind it should still be where you left
/// it when you land.
struct FileFinderOverlay: View {
    @Environment(WorkspaceStore.self) private var store

    /// Wide enough for a deep path next to a file name, and no wider — the list
    /// is read down the left edge.
    private static let panelWidth: CGFloat = 620
    /// Ten rows and a bit, so it is clear the list carries on past the fold.
    private static let listHeight: CGFloat = 330
    private static let rowHeight: CGFloat = 28
    private static let panelShape = RoundedRectangle(cornerRadius: 12, style: .continuous)

    @FocusState private var isTyping: Bool

    var body: some View {
        ZStack(alignment: .top) {
            // Dims the window and swallows the clicks that would otherwise land
            // on the panes underneath while the keyboard is busy up here.
            Color.black.opacity(0.18)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { store.closeFileFinder() }

            panel
                // Below the traffic lights, and high enough that the list grows
                // downwards into empty window rather than towards the bottom.
                .padding(.top, 84)
        }
        .transition(.opacity)
        .onWindowKeyEvent { event, window in handle(event, in: window) }
        // The palette is opened by a shortcut, so it has to arrive with the
        // keyboard already in its field — there is nothing else to click.
        .onAppear { isTyping = true }
    }

    private var panel: some View {
        VStack(spacing: 0) {
            field
            Divider()
            if store.fileFinderMatches.isEmpty {
                emptyState
            } else {
                list
            }
            Divider()
            footer
        }
        .frame(width: Self.panelWidth)
        .background(.ultraThinMaterial, in: Self.panelShape)
        .overlay(Self.panelShape.strokeBorder(.white.opacity(0.14)))
        .shadow(color: .black.opacity(0.32), radius: 26, y: 10)
    }

    // MARK: - Field

    private var field: some View {
        @Bindable var store = store
        return HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField(placeholder, text: $store.fileFinderQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .focused($isTyping)
                // ⏎ is taken by the key monitor below, which opens the picked
                // row; this only keeps the field from beeping if it ever is not.
                .onSubmit { store.openSelectedFile() }

            if store.isListingFiles {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
    }

    private var placeholder: String {
        guard let name = store.selectedProject?.name else { return "Search files" }
        return "Search files in \(name)"
    }

    // MARK: - Results

    private var list: some View {
        ScrollViewReader { scroller in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(store.fileFinderMatches.enumerated()), id: \.element.id) { index, match in
                        FileFinderRow(
                            match: match,
                            isSelected: index == store.fileFinderSelection,
                            height: Self.rowHeight,
                            open: { store.open(match) }
                        )
                        .id(match.id)
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(height: min(Self.listHeight, height(of: store.fileFinderMatches.count)))
            .scrollBounceBehavior(.basedOnSize)
            // The arrows walk past the fold in both directions, so the list
            // follows the row rather than the other way round.
            .onChange(of: store.fileFinderSelection) { _, index in
                guard store.fileFinderMatches.indices.contains(index) else { return }
                scroller.scrollTo(store.fileFinderMatches[index].id, anchor: .bottom)
            }
            // A new query is a new list, and it is read from the top.
            .onChange(of: store.fileFinderMatches.first?.id) { _, first in
                guard let first else { return }
                scroller.scrollTo(first, anchor: .top)
            }
        }
    }

    /// What the list would like to be: short lists shrink the panel instead of
    /// leaving a band of empty glass under three results.
    private func height(of rows: Int) -> CGFloat {
        CGFloat(rows) * Self.rowHeight + 8
    }

    @ViewBuilder
    private var emptyState: some View {
        Text(store.fileFinderQuery.trimmingCharacters(in: .whitespaces).isEmpty
            ? (store.isListingFiles ? "Reading the repository…" : "Type to find a file")
            : "No file matches that")
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .frame(height: 44)
    }

    private var footer: some View {
        HStack(spacing: 0) {
            Text("↑↓ move · ⏎ open · ⎋ close")
            Spacer(minLength: 12)
            if store.fileFinderCount > 0 {
                Text("\(store.fileFinderCount) files")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 14)
        .frame(height: 26)
    }

    // MARK: - Keys

    private static let returnKeyCode: UInt16 = 36
    private static let keypadEnterKeyCode: UInt16 = 76
    private static let escapeKeyCode: UInt16 = 53
    private static let downArrowKeyCode: UInt16 = 125
    private static let upArrowKeyCode: UInt16 = 126

    /// Taken from the window rather than bound to the field: a `TextField` keeps
    /// the arrows for its own caret, and ⎋ inside one means "undo what I typed"
    /// — here every one of them belongs to the list.
    private func handle(_ event: NSEvent, in window: NSWindow) -> Bool {
        guard store.isFindingFiles, window.attachedSheet == nil else { return false }
        // ⌘⇥ and friends are the system's; nothing here wants a modifier.
        guard !event.modifierFlags.contains(.command) else { return false }

        switch event.keyCode {
        case Self.escapeKeyCode:
            store.closeFileFinder()
        case Self.downArrowKeyCode:
            store.moveFileFinderSelection(by: 1)
        case Self.upArrowKeyCode:
            store.moveFileFinderSelection(by: -1)
        case Self.returnKeyCode, Self.keypadEnterKeyCode:
            store.openSelectedFile()
        default:
            return false
        }
        return true
    }
}

/// One file in the palette: its icon, its name, and the folders above it.
private struct FileFinderRow: View {
    let match: FileFinder.Match
    let isSelected: Bool
    let height: CGFloat
    let open: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 7) {
            icon
            marked(match.name, offsets: nameOffsets)
                .font(.system(size: 12.5))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))

            if !match.folder.isEmpty {
                marked(match.folder, offsets: folderOffsets)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    // From the front: two files of the same name are told apart
                    // by the folder they sit in, and that is what a long path
                    // loses first when it is cut from the end.
                    .truncationMode(.head)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.75)) : AnyShapeStyle(.secondary))
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: height)
        .background(background, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .pointerCursor()
        .onTapGesture(perform: open)
    }

    @ViewBuilder
    private var icon: some View {
        if let brand = FileIcon.brand(for: url) {
            BrandMark(name: brand.name, size: 12, color: isSelected ? .white : brand.color)
                .frame(width: 17)
        } else {
            Image(systemName: FileIcon.symbol(for: url))
                .font(.system(size: 11))
                .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(FileIcon.tint(for: url)))
                .frame(width: 17)
        }
    }

    /// Only the name matters to the icon, so a relative path is URL enough.
    private var url: URL { URL(fileURLWithPath: match.path) }

    private var background: AnyShapeStyle {
        if isSelected { return AnyShapeStyle(.tint) }
        return isHovering ? AnyShapeStyle(.quaternary.opacity(0.5)) : AnyShapeStyle(.clear)
    }

    /// The matched offsets are into the whole path, and the row draws the name
    /// and the folder as two pieces of text — so each piece takes its own.
    private var nameOffsets: Set<Int> {
        let start = match.nameStart
        return Set(match.highlighted.filter { $0 >= start }.map { $0 - start })
    }

    private var folderOffsets: Set<Int> {
        let start = match.nameStart
        return Set(match.highlighted.filter { $0 < start })
    }

    /// The text with the matched letters picked out, built in runs rather than a
    /// piece per character.
    private func marked(_ text: String, offsets: Set<Int>) -> Text {
        guard !offsets.isEmpty else { return Text(text) }

        var result = Text("")
        var run = ""
        var runIsMatch = false

        func flush() {
            guard !run.isEmpty else { return }
            let piece = Text(run)
            result = result + (runIsMatch
                ? piece.foregroundStyle(highlight).fontWeight(.semibold)
                : piece)
            run = ""
        }

        for (offset, character) in text.enumerated() {
            let isMatch = offsets.contains(offset)
            if isMatch != runIsMatch {
                flush()
                runIsMatch = isMatch
            }
            run.append(character)
        }
        flush()
        return result
    }

    /// On a filled row the accent colour is the background, so the matched
    /// letters are picked out in weight and white instead.
    private var highlight: AnyShapeStyle {
        isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.tint)
    }
}
