import AppKit
import SwiftUI

/// Window shell: repositories on the left, viewer in the middle, the
/// per-project navigator on the right. Both side panels collapse.
struct ContentView: View {
    @Environment(WorkspaceStore.self) private var store
    @Environment(ToolInventory.self) private var tools

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
        // Each pane draws its own header row, so the window needs no title of
        // its own; this only names the window in the Window menu.
        .navigationTitle("Workspace")
        .overlay(alignment: .bottom) { statusToast }
        // Checked once at launch, so the sidebar's Settings button can point out
        // a missing `gh`/`bkt` before a pull request list comes back empty.
        .task { await tools.refresh() }
        // Asked once per repository, right after it is added.
        .sheet(item: $store.gitHubAccountPrompt) { prompt in
            GitHubAccountSheet(prompt: prompt)
        }
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
