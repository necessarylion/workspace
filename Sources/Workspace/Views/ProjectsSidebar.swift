import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Right sidebar: every repository the user added, as a card.
struct ProjectsSidebar: View {
    @Environment(WorkspaceStore.self) private var store
    @Environment(ToolInventory.self) private var tools

    /// The repository being dragged, while a reorder is in progress.
    @State private var draggingID: URL?

    var body: some View {
        VStack(spacing: 0) {
            header

            if store.projects.isEmpty {
                ContentUnavailableView {
                    Label("No repositories", systemImage: "folder.badge.plus")
                } description: {
                    Text("Add the folder of one you already have, or make a new one here.")
                } actions: {
                    VStack(spacing: 8) {
                        Button("Add Existing Folder…") { store.promptForProjectFolder() }
                            .pointerCursor()
                        HStack(spacing: 12) {
                            Button("New") { store.showNewRepository(.create) }
                                .pointerCursor()
                            Button("Clone…") { store.showNewRepository(.clone) }
                                .pointerCursor()
                        }
                        .buttonStyle(.link)
                    }
                }
            } else {
                searchField
                list
            }

            Divider()
            footer
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var isFiltering: Bool {
        !store.projectSearchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    @ViewBuilder
    private var list: some View {
        let projects = store.visibleProjects
        if projects.isEmpty {
            VStack(spacing: 6) {
                Text("No repositories match")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Clear filter") { store.projectSearchText = "" }
                    .buttonStyle(.link)
                    .pointerCursor()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 7) {
                    ForEach(projects) { project in
                        card(project)
                    }
                }
                .padding(.horizontal, 10)
                // The working badge stands half its height above its card's top
                // edge, and the scroll view clips at its own — without this the
                // first card's badge would be the one card's badge that is cut
                // in half.
                .padding(.top, ClaudeWorkingBadge.height / 2 + 2)
                .padding(.bottom, 10)
                .animation(.easeInOut(duration: 0.15), value: store.projects.map(\.id))
            }
        }
    }

    /// Reordering is off while the list is filtered: the cards on screen are
    /// only part of the order, so dropping between them means nothing. Pinned
    /// cards are out of it too — their block is sorted by name.
    @ViewBuilder
    private func card(_ project: Project) -> some View {
        ProjectCard(project: project, isSelected: project.id == store.selectedProjectID)
            .pointerCursor()
            .onTapGesture { store.selectedProjectID = project.id }
            .contextMenu { menu(project) }
            .ifReorderable(!isFiltering && !project.isPinned) { card in
                card
                    .onDrag {
                        draggingID = project.id
                        return NSItemProvider(object: project.url.path as NSString)
                    }
                    .onDrop(
                        of: [.plainText],
                        delegate: ProjectReorderDropDelegate(
                            target: project.id,
                            store: store,
                            draggingID: $draggingID
                        )
                    )
            }
    }

    /// Lines up with the viewer's header row, and leaves the left end free:
    /// with the window's title bar hidden the traffic lights sit there. It
    /// carries no title or count — only the home terminal button, at the far
    /// end.
    private var header: some View {
        HStack {
            Spacer()
            HomeTerminalButton()
        }
        .buttonStyle(.borderless)
        .padding(.leading, 78)
        .padding(.trailing, 12)
        .frame(height: 38)
        .background(.bar)
    }

    /// Matches the files pane's filter row, so both sidebars behave the same.
    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.caption)
            TextField(
                "Filter repositories",
                text: Binding(
                    get: { store.projectSearchText },
                    set: { store.projectSearchText = $0 }
                )
            )
            .textFieldStyle(.plain)
            if isFiltering {
                Button {
                    store.projectSearchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear the filter")
                .pointerCursor()
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            AddRepositoryMenu {
                Label("Add Repository", systemImage: "plus")
            }
            Spacer()
            updateButton
            settingsButton
            Button {
                store.refreshAll()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .help("Refresh every repository")
            .disabled(store.projects.isEmpty)
            .pointerCursor(!store.projects.isEmpty)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    /// There only while a new version of the app is waiting — the one place a
    /// banner that has been put away can still be found.
    @ViewBuilder
    private var updateButton: some View {
        if let release = AppUpdater.shared.pending {
            Button {
                SettingsWindow.showUpdates()
            } label: {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(.blue)
            }
            .buttonStyle(.plain)
            .help("Workspace \(release.version.text) is available")
            .pointerCursor()
        }
    }

    /// Opens Settings, with a dot when a tool the repositories here depend on is
    /// missing or logged out — the reason a PR list would come back empty.
    private var settingsButton: some View {
        SettingsLink {
            Image(systemName: "gearshape")
                .overlay(alignment: .topTrailing) {
                    if needsAttention {
                        Circle()
                            .fill(.orange)
                            .frame(width: 5, height: 5)
                            .offset(x: 3, y: -2)
                    }
                }
        }
        .buttonStyle(.plain)
        .help(needsAttention ? "Settings — a required tool needs attention" : "Settings")
        .pointerCursor()
    }

    /// `claude` and `rg` are left out: their actions are optional — the file
    /// search falls back to `git grep` — and a missing `bkt` only matters once a
    /// Bitbucket repository is here.
    private var needsAttention: Bool {
        tools.unresolved.contains { tool in
            switch tool {
            case .git: true
            case .gh: store.projects.contains { $0.host == .github }
            case .bkt: store.projects.contains { $0.host == .bitbucket }
            case .claude, .rg: false
            }
        }
    }

    @ViewBuilder
    private func menu(_ project: Project) -> some View {
        Button(project.isPinned ? "Unpin from Top" : "Pin to Top") {
            store.togglePin(project)
        }
        Divider()
        Button("Refresh") { Task { await project.refresh() } }
        Button("Open Terminal") { store.openTerminal(in: project) }
        Divider()
        if project.host == .github {
            GitHubAccountMenu(project: project)
            Divider()
        }
        if let url = project.remote?.webURL {
            Button("Open Repository in Browser") { NSWorkspace.shared.open(url) }
        }
        Button("Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([project.url])
        }
        Divider()
        Button("Remove from Workspace") { store.removeProject(project) }
    }
}

/// Reordering the sidebar by dragging a card onto another one. `LazyVStack` has
/// no `onMove` of its own — the list is rearranged as the drag passes over each
/// card, and the arrangement is saved when the drag is let go.
private struct ProjectReorderDropDelegate: DropDelegate {
    /// The card being hovered over — where the dragged repository should land.
    let target: URL
    let store: WorkspaceStore
    @Binding var draggingID: URL?

    func dropEntered(info: DropInfo) {
        guard let draggingID else { return }
        store.moveProject(withID: draggingID, toPositionOf: target)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggingID = nil
        return true
    }
}

private extension View {
    /// `onDrag` has no disabled state, so the reorder modifiers are attached
    /// only when they apply.
    @ViewBuilder
    func ifReorderable<Modified: View>(
        _ enabled: Bool,
        _ transform: (Self) -> Modified
    ) -> some View {
        if enabled {
            transform(self)
        } else {
            self
        }
    }
}

/// One press, one prompt in the home folder — no repository needed and no menu
/// in the way. It returns to the home shell you already have; ⌘T from inside it
/// opens another. The shells themselves are listed in the navigator's Terminals
/// tab.
///
/// The badge counts the home shells that are open, so the ones no repository
/// lists are still visible from anywhere in the app. Its own view because the
/// pane and the rail it folds to both carry it — a terminal that belongs to no
/// repository should not be reachable only while the pane is open.
struct HomeTerminalButton: View {
    @Environment(WorkspaceStore.self) private var store

    var body: some View {
        let count = store.shellTerminals(in: .home).count

        return Button {
            store.openGlobalTerminal()
        } label: {
            Image(systemName: "terminal")
                .overlay(alignment: .topTrailing) {
                    if count > 0 {
                        Text("\(count)")
                            .font(.system(size: 8, weight: .bold).monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 3)
                            .frame(minWidth: 12, minHeight: 12)
                            .background(Capsule().fill(.tint))
                            .offset(x: 8, y: -6)
                    }
                }
                // Room for the badge, so it never runs past the pane's edge.
                .padding(.trailing, count > 0 ? 8 : 0)
        }
        .help(count == 0
            ? "Open a terminal in your home folder (⇧⌘T)"
            : "\(count) terminal\(count == 1 ? "" : "s") in your home folder (⇧⌘T)")
        .pointerCursor()
    }
}

/// What the repositories pane collapses to, rather than nothing at all: a rail
/// of every repository as a square card — its host's mark and its folder name —
/// so switching repository never costs unfolding the pane first.
///
/// It is also what holds the traffic lights once the pane is folded, which is
/// why it is no narrower than they are: hidden entirely, the lights floated over
/// the viewer's own header and the row had to leave a hole for them.
struct CollapsedProjectsRail: View {
    @Environment(WorkspaceStore.self) private var store

    /// Wide enough for the traffic lights to sit clear of the viewer beside it,
    /// and no wider — the header row is theirs alone, so nothing the rail carries
    /// competes with them for it.
    static let width: CGFloat = 76

    var body: some View {
        VStack(spacing: 0) {
            // Empty, but the same height as every other header row: the traffic
            // lights live in it.
            Color.clear
                .frame(height: 38)
                .frame(maxWidth: .infinity)
                .background(.bar)

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(store.projects) { project in
                        card(project)
                    }
                }
                // Same headroom the wide list gives the badge, for the same
                // reason: the top square's would otherwise be clipped.
                .padding(.top, ClaudeWorkingBadge.height / 2 + 2)
                .padding(.bottom, 8)
            }

            // The pane's footer, down to the two controls that belong to no
            // repository in particular: a shell in the home folder, and the way
            // to add a repository at all. The header above is the traffic
            // lights' — this is the only row on the rail that is free.
            Divider()
            HStack(spacing: 12) {
                HomeTerminalButton()
                AddRepositoryMenu {
                    Image(systemName: "plus")
                }
                .help("Add, create or clone a repository")
            }
            .buttonStyle(.borderless)
            .frame(maxWidth: .infinity)
            .frame(height: 32)
        }
        .frame(width: Self.width)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    /// The search box is not on screen here, so the rail lists every repository
    /// rather than `visibleProjects` — a filter left running would hide cards
    /// with nothing on the rail to clear it.
    private func card(_ project: Project) -> some View {
        let isSelected = project.id == store.selectedProjectID

        return VStack(spacing: 3) {
            ZStack {
                RoundedRectangle(cornerRadius: 9)
                    .fill(
                        isSelected
                            ? AnyShapeStyle(.tint.opacity(0.16))
                            : AnyShapeStyle(.quaternary.opacity(0.25))
                    )
                RoundedRectangle(cornerRadius: 9)
                    .stroke(
                        isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear),
                        lineWidth: 1.2
                    )
                GitHostIcon(host: project.host, size: 19)
            }
            .frame(width: 44, height: 44)
            .claudeWorkingBadge(count: store.workingClaudeCount(in: project))

            // The name is the only way to tell two GitHub repositories apart, so
            // it is worth the two lines even at this width; the tooltip carries
            // the whole of it for the ones that still do not fit.
            Text(project.name)
                .font(.system(size: 9))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .onTapGesture { store.selectedProjectID = project.id }
        .pointerCursor()
        .help(project.name)
    }
}

/// One repository, summarised.
struct ProjectCard: View {
    @Environment(WorkspaceStore.self) private var store

    let project: Project
    let isSelected: Bool

    /// The star only sits on the card while it is pinned — otherwise it appears
    /// under the pointer, so an unpinned list stays quiet.
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                GitHostIcon(host: project.host)
                Text(project.name)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Spacer()
                if project.isLoadingPullRequests {
                    ProgressView().controlSize(.mini)
                }
                if project.isPinned || isHovering {
                    starButton
                }
            }

            if let status = project.gitStatus {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.triangle.branch")
                    Text(status.branch)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if status.ahead > 0 { Text("↑\(status.ahead)") }
                    if status.behind > 0 { Text("↓\(status.behind)") }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                Text("Not a git repository")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            HStack(spacing: 5) {
                Pill(
                    text: "\(project.pullRequests.count) PR",
                    color: project.pullRequests.isEmpty ? .secondary : .accentColor
                )
                Pill(
                    text: project.changeCount == 0 ? "clean" : "\(project.changeCount) changed",
                    color: project.changeCount == 0 ? .green : .orange
                )
                if !project.ports.isEmpty {
                    Pill(text: "\(project.ports.count) port", color: .green)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(isSelected ? AnyShapeStyle(.tint.opacity(0.14)) : AnyShapeStyle(.quaternary.opacity(0.22)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .stroke(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear), lineWidth: 1.2)
        )
        .claudeWorkingBadge(count: store.workingClaudeCount(in: project))
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
    }

    private var starButton: some View {
        Button {
            store.togglePin(project)
        } label: {
            Image(systemName: project.isPinned ? "star.fill" : "star")
                .font(.caption)
                .foregroundStyle(project.isPinned ? AnyShapeStyle(.yellow) : AnyShapeStyle(.tertiary))
        }
        .buttonStyle(.plain)
        .help(project.isPinned ? "Unpin from the top" : "Pin to the top")
        .pointerCursor()
    }
}

extension View {
    /// Rides this tile's top-right corner with the badge that says a repository
    /// has a turn running in it.
    ///
    /// The card and the folded rail's square wear it the same way — the corner
    /// is where a badge belongs, and a mark tucked into the card's header row
    /// instead read as one more of the things in that row rather than as a
    /// state the whole repository is in. Nothing is drawn while no turn is
    /// running, so nothing is reserved for it either.
    ///
    /// It is lifted clear of the tile's own top inset rather than merely nudged
    /// off the corner: the card puts its star in that corner too, and a badge
    /// dipping into the header row would cover the star's top edge — and, being
    /// the layer above, take the click meant for it — the moment a second
    /// conversation widened the chip.
    func claudeWorkingBadge(count: Int) -> some View {
        overlay(alignment: .topTrailing) {
            // Sat on the corner rather than over it: half the badge hanging past
            // each edge is what reads as a badge, and any less has it looking
            // like something that landed on the tile. Half its height above is
            // also what clears a 10-point inset, so the two wants are one number.
            ClaudeWorkingBadge(count: count)
                .offset(x: 6, y: -ClaudeWorkingBadge.height / 2)
        }
    }
}

/// The sign that a repository has a conversation mid-turn, for its card and for
/// its square on the folded rail. Placed by `claudeWorkingBadge(count:)`, which
/// is what keeps the two the same badge rather than two of them.
///
/// Claude's own mark rather than a spinner, and it breathes rather than spins:
/// there is already a spinner on the card for the pull request load, and two
/// turning things a few points apart say nothing about which is which. Nothing
/// is drawn at all when no turn is running — a badge that is always there is
/// only furniture.
struct ClaudeWorkingBadge: View {
    let count: Int

    private static let size: CGFloat = 13
    private static let verticalPadding: CGFloat = 3

    /// What the badge stands, so `claudeWorkingBadge(count:)` can place it by
    /// its own size rather than by a number that has to be kept in step with
    /// one. The chip is held to it below, which is what makes it the truth for
    /// any count — the digit's own line height would otherwise set it.
    static let height = size + verticalPadding * 2

    @State private var isDim = false

    var body: some View {
        if count > 0 {
            HStack(spacing: 3) {
                ClaudeMark(size: Self.size)
                // Only worth the width once there is more than one — a single
                // "1" beside the mark says nothing the mark did not.
                if count > 1 {
                    Text("\(count)")
                        .font(.caption2.weight(.semibold).monospacedDigit())
                }
            }
            .frame(height: Self.size)
            // The chip is what keeps a second conversation from reading as a
            // digit dropped next to the mark: hanging off a card's corner over
            // whatever is behind it, the two need something to say they are one
            // badge. A single mark gets it too — the capsule closes to a disc
            // around it, so the badge grows rather than changing shape.
            .padding(.horizontal, 4)
            .padding(.vertical, Self.verticalPadding)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.quaternary, lineWidth: 0.5))
            .opacity(isDim ? 0.35 : 1)
            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: isDim)
            .onAppear { isDim = true }
            .help(count == 1
                ? "A Claude conversation is working"
                : "\(count) Claude conversations are working")
        }
    }
}

struct Pill: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2.monospacedDigit())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.16), in: Capsule())
            .foregroundStyle(color)
    }
}
