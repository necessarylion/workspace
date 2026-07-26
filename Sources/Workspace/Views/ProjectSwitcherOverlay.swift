import SwiftUI

/// ⌃⇥ — the repositories in a row, the way ⌘⇥ shows apps. It sits over the
/// window on glass while ⌃ is held: every further ⇥ moves the ring along, and
/// letting go of ⌃ switches to whatever it landed on.
struct ProjectSwitcherOverlay: View {
    @Environment(WorkspaceStore.self) private var store

    /// One tile is a little wider than the sidebar's card, because a row of
    /// them has to be read at a glance rather than scanned down.
    private static let tileWidth: CGFloat = 156
    private static let tileSpacing: CGFloat = 10
    /// Room for the ring's stroke on the first and last tile, which would
    /// otherwise be clipped by the scroll view.
    private static let rowInset: CGFloat = 2
    /// Past six tiles the row scrolls rather than growing across the window.
    private static let maxTilesOnScreen = 6
    private static let panelShape = RoundedRectangle(cornerRadius: 20, style: .continuous)

    var body: some View {
        ZStack {
            // Dims what is behind so the row reads as the only thing on screen,
            // and swallows the clicks that would otherwise land on the panes
            // underneath while the keyboard is busy here.
            Color.black.opacity(0.18)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { store.cancelProjectSwitcher() }

            panel
        }
        .transition(.opacity)
    }

    private var panel: some View {
        VStack(spacing: 12) {
            row
            // Kept short so it is never the widest thing in the panel: two
            // tiles is the narrowest the row can be — the switcher does not
            // open for a single repository — and this stays inside that.
            Text("⇥ next · ⇧⇥ back · let go of ⌃ to switch")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(18)
        .background(.ultraThinMaterial, in: Self.panelShape)
        .overlay(Self.panelShape.strokeBorder(.white.opacity(0.14)))
        .shadow(color: .black.opacity(0.3), radius: 26, y: 10)
        .padding(40)
    }

    /// How wide the row of tiles actually is. A scroll view takes every point it
    /// is offered, so with three repositories on a six-wide panel the last one
    /// would be followed by a stretch of empty glass — the width has to be told,
    /// not left to it. Tiles are a fixed size, so it can simply be counted.
    private var rowWidth: CGFloat {
        let onScreen = min(store.projects.count, Self.maxTilesOnScreen)
        guard onScreen > 0 else { return 0 }
        let tiles = CGFloat(onScreen) * Self.tileWidth
        let gaps = CGFloat(onScreen - 1) * Self.tileSpacing
        return tiles + gaps + 2 * Self.rowInset
    }

    private var row: some View {
        ScrollViewReader { scroller in
            ScrollView(.horizontal) {
                HStack(spacing: Self.tileSpacing) {
                    ForEach(Array(store.projects.enumerated()), id: \.element.id) { index, project in
                        tile(project, isRinged: index == store.switcherIndex)
                            .id(project.id)
                            .pointerCursor()
                            .onTapGesture {
                                store.moveProjectSwitcher(to: index)
                                store.commitProjectSwitcher()
                            }
                    }
                }
                .padding(Self.rowInset)
            }
            // `maxWidth` rather than `width`: it fits the tiles exactly when
            // there are few, and still gives way on a window too narrow for six.
            .frame(maxWidth: rowWidth)
            .scrollBounceBehavior(.basedOnSize)
            // The ring can walk off the end of a long row, so the row follows.
            .onChange(of: store.switcherIndex) { _, index in
                guard let index, store.projects.indices.contains(index) else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    scroller.scrollTo(store.projects[index].id, anchor: .center)
                }
            }
        }
    }

    private func tile(_ project: Project, isRinged: Bool) -> some View {
        VStack(spacing: 9) {
            GitHostIcon(host: project.host, size: 30)
                // Only the brand marks read `size`; the SF Symbol a plain
                // folder falls back to takes its size from the font.
                .font(.system(size: 26))
                .frame(height: 32)

            Text(project.name)
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)

            // A repository is identified by its branch as much as its name, and
            // two checkouts of the same repo are told apart by nothing else.
            Text(project.gitStatus?.branch ?? project.url.lastPathComponent)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 10)
        .frame(width: Self.tileWidth)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(isRinged ? AnyShapeStyle(.tint.opacity(0.22)) : AnyShapeStyle(.clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(isRinged ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear), lineWidth: 2)
        )
        .contentShape(Rectangle())
    }
}
