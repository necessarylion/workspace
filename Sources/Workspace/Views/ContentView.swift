import AppKit
import SwiftUI

/// Window shell: repositories on the left, viewer in the middle, the
/// per-project navigator on the right. Both side panels collapse.
struct ContentView: View {
    @Environment(WorkspaceStore.self) private var store
    @Environment(ToolInventory.self) private var tools
    private var servers: ManagedLanguageServers { .shared }

    /// The panes are laid out by hand. `HSplitView` and `.inspector` are both
    /// AppKit-backed, and both pin their columns below the window's title bar
    /// safe area whatever `ignoresSafeArea` says, which left an empty band
    /// above the header rows.
    @State private var sidebarWidth: CGFloat = 253
    @State private var navigatorWidth: CGFloat = 300

    var body: some View {
        @Bindable var store = store
        return HStack(spacing: 0) {
            if store.showsProjects {
                ProjectsSidebar()
                    .frame(width: sidebarWidth)
                    .frame(maxHeight: .infinity)
                PaneResizer(width: $sidebarWidth, range: 140...380)
            } else {
                // Folded, the pane leaves a rail behind rather than nothing —
                // the repositories are still one click apart.
                CollapsedProjectsRail()
                    .frame(maxHeight: .infinity)
            }
            ViewerView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if store.showsNavigator {
                PaneResizer(width: $navigatorWidth, range: 230...460, growsLeftwards: true)
                NavigatorView()
                    .frame(width: navigatorWidth)
                    .frame(maxHeight: .infinity)
            }
        }
        // The panes draw their own header rows and make their own room for the
        // traffic lights, so none of them wants the title bar's safe area.
        .ignoresSafeArea()
        // The window opens with nothing focused rather than in the sidebar's
        // filter box, so ⎋ closes the open item from the first keystroke.
        .withoutInitialTextFocus()
        // Each pane draws its own header row, so the window needs no title of
        // its own; this only names the window in the Window menu.
        .navigationTitle("Workspace")
        .overlay(alignment: .bottom) { statusToast }
        .overlay(alignment: .bottomTrailing) { UpdateBanner() }
        .overlay {
            if store.isSwitchingProjects {
                ProjectSwitcherOverlay()
            }
        }
        .overlay {
            if store.isFindingFiles {
                FileFinderOverlay()
            }
        }
        // Put once, the first time a repository wants a server this Mac has not
        // got. Whichever way it is answered, it is not asked again — Settings →
        // Language Servers is where it is changed after that.
        .alert(
            "Install language servers for you?",
            isPresented: Binding(
                get: { servers.consentRequest != nil },
                // Guarded, because pressing Install dismisses the alert too:
                // without this, the dismissal would arrive after the answer and
                // turn a yes into a no.
                set: { if !$0, servers.consentRequest != nil { servers.answerConsent(allow: false) } }
            )
        ) {
            Button("Install") { servers.answerConsent(allow: true) }
            Button("Not Now", role: .cancel) { servers.answerConsent(allow: false) }
        } message: {
            Text(consentMessage)
        }
        .animation(.easeOut(duration: 0.12), value: store.isSwitchingProjects)
        .animation(.easeOut(duration: 0.1), value: store.isFindingFiles)
        .onWindowKeyEvent(matching: [.keyDown, .flagsChanged]) { event, window in
            handleSwitcherKey(event, in: window)
        }
        // Checked once at launch, so the sidebar's Settings button can point out
        // a missing `gh`/`bkt` before a pull request list comes back empty.
        .task { await tools.refresh() }
        // The app's own releases, asked after at most six hours. Starting it
        // here rather than in the app's `init` keeps a launch free of network.
        .task { AppUpdater.shared.startAutomaticChecks() }
        // The sidebar's branch, changes and pull request counts, read again
        // every five minutes while the app is in front.
        .task { store.startAutomaticRefresh() }
        // Asked once per repository, right after it is added.
        .sheet(item: $store.gitHubAccountPrompt) { prompt in
            GitHubAccountSheet(prompt: prompt)
        }
        // `git init` in a new folder, or a clone from a pasted URL.
        .sheet(item: $store.newRepository) { request in
            NewRepositorySheet(request: request)
        }
    }

    /// Names what would be installed, so the answer is given about something
    /// concrete rather than about a policy.
    private var consentMessage: String {
        let wanted = servers.consentRequest ?? []
        let names = wanted.sorted().joined(separator: ", ")
        return """
        This repository wants \(names).

        They would be downloaded into the app's own folder in Application \
        Support. Your Homebrew, your global npm packages and your gems are not \
        touched, and removing them is one button in Settings.
        """
    }

    // MARK: - Repository switcher (⌃⇥ by default)

    private static let returnKeyCode: UInt16 = 36
    private static let leftArrowKeyCode: UInt16 = 123
    private static let rightArrowKeyCode: UInt16 = 124
    /// ⎋ by keycode rather than `NSEvent.isEscape`, because ⌃ is usually still
    /// down when it is pressed to call the whole thing off.
    private static let escapeKeyCode: UInt16 = 53

    /// The switcher has to be caught here rather than bound to a control: the
    /// terminal keeps every key it is given, and holding a modifier across
    /// several presses is not something a shortcut can express. Returns true
    /// for the keys it takes.
    ///
    /// Which key it is comes from Settings, so ⇧ is read as "the other way"
    /// rather than being part of it, and whatever else the chord holds is what
    /// keeps the row up — let go of it and the highlighted repository is the
    /// one you get. A chord with no modifiers at all leaves the row up until
    /// ⏎ or ⎋, since there is then nothing to let go of.
    private func handleSwitcherKey(_ event: NSEvent, in window: NSWindow) -> Bool {
        // A sheet is its own conversation; it finishes first.
        guard window.attachedSheet == nil else { return false }
        let chord = KeyboardShortcuts.shared.chord(for: .switchRepository)

        if event.type == .flagsChanged {
            let hold = chord?.holdFlags ?? []
            if store.isSwitchingProjects, !hold.isEmpty,
               event.modifierFlags.intersection(hold).isEmpty {
                store.commitProjectSwitcher()
            }
            return false
        }

        if let chord, chord.matchesIgnoringShift(event) {
            // ⇧ reverses whichever direction the chord itself means.
            let shifted = event.modifierFlags.contains(.shift)
            store.cycleProjectSwitcher(backwards: shifted != chord.modifiers.contains(.shift))
            return true
        }

        // The rest only mean anything while the row is up, and while it is up
        // they are taken from whatever is underneath.
        guard store.isSwitchingProjects else { return false }
        switch event.keyCode {
        case Self.leftArrowKeyCode:
            store.moveProjectSwitcher(by: -1)
        case Self.rightArrowKeyCode:
            store.moveProjectSwitcher(by: 1)
        case Self.returnKeyCode:
            store.commitProjectSwitcher()
        case Self.escapeKeyCode:
            store.cancelProjectSwitcher()
        default:
            return false
        }
        return true
    }

    /// A rectangle with softened corners rather than a capsule: a git error runs
    /// to several lines, and a capsule's ends bow in around them.
    private static let toastShape = RoundedRectangle(cornerRadius: 10, style: .continuous)

    @ViewBuilder
    private var statusToast: some View {
        if let toast = store.statusMessage {
            let isFailure = toast.kind == .failure
            Text(toast.text)
                .font(.callout)
                .foregroundStyle(isFailure ? AnyShapeStyle(Color.red) : AnyShapeStyle(.primary))
                .multilineTextAlignment(.leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: Self.toastShape)
                .overlay {
                    if isFailure {
                        Self.toastShape.strokeBorder(Color.red.opacity(0.4))
                    }
                }
                .shadow(radius: 6, y: 2)
                .padding(.bottom, 40)
                .transition(.opacity)
                .task(id: toast) {
                    // A failure is worth reading, so it lingers.
                    try? await Task.sleep(for: .seconds(isFailure ? 6 : 2.5))
                    store.statusMessage = nil
                }
        }
    }
}

/// Draggable seam between two panes: a hairline to look at, wider to grab.
struct PaneResizer: View {
    @Binding var width: CGFloat
    let range: ClosedRange<CGFloat>
    /// True when the pane being sized sits to the right of the seam, so
    /// dragging left makes it wider rather than narrower.
    var growsLeftwards = false

    @State private var widthBeforeDrag: CGFloat?

    var body: some View {
        Divider()
            .overlay {
                Color.clear
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { value in
                                let start = widthBeforeDrag ?? width
                                widthBeforeDrag = start
                                let delta = growsLeftwards
                                    ? -value.translation.width
                                    : value.translation.width
                                width = min(range.upperBound, max(range.lowerBound, start + delta))
                            }
                            .onEnded { _ in widthBeforeDrag = nil }
                    )
                    .onHover { inside in
                        if inside {
                            NSCursor.resizeLeftRight.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
            }
    }
}
