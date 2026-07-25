import SwiftUI

/// Window shell: repositories on the left, viewer in the middle, the
/// per-project navigator on the right. Both side panels collapse.
struct ContentView: View {
    @Environment(WorkspaceStore.self) private var store

    var body: some View {
        // A plain split, not NavigationSplitView: the repositories panel should
        // be a flat panel like the navigator on the right, not a translucent
        // Finder-style source list.
        HSplitView {
            if store.showsProjects {
                ProjectsSidebar()
                    .frame(minWidth: 155, idealWidth: 175, maxWidth: 380, maxHeight: .infinity)
            }
            ViewerView()
                .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)
                .inspector(isPresented: Binding(
                    get: { store.showsNavigator },
                    set: { store.showsNavigator = $0 }
                )) {
                    NavigatorView()
                        .inspectorColumnWidth(min: 230, ideal: 300, max: 460)
                }
                .toolbar { toolbarContent }
        }
        // The open item is named by the viewer's own header row, not the
        // window title — a two-line toolbar title renders badly here.
        .navigationTitle("Workspace")
        .overlay(alignment: .bottom) { statusToast }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button {
                withAnimation { store.showsProjects.toggle() }
            } label: {
                Label("Repositories", systemImage: "sidebar.leading")
            }
            .help("Show or hide the repositories sidebar (⌘0)")

            Button {
                store.goBack()
            } label: {
                Label("Back", systemImage: "chevron.left")
            }
            .disabled(!store.canGoBack)
            .help(store.backTitle.map { "Back to \($0)" } ?? "Back")

            Button {
                store.goForward()
            } label: {
                Label("Forward", systemImage: "chevron.right")
            }
            .disabled(!store.canGoForward)
            .help(store.forwardTitle.map { "Forward to \($0)" } ?? "Forward")
        }

        ToolbarItemGroup {
            if store.current?.document?.isMarkdown == true {
                Toggle(isOn: Binding(
                    get: { store.markdownPreview },
                    set: { store.markdownPreview = $0 }
                )) {
                    Label("Preview", systemImage: "eye")
                }
                .help("Preview Markdown")
            }

            // Collapse button and tab picker share the toolbar row, toggle on
            // the left of the tabs.
            Button {
                withAnimation { store.showsNavigator.toggle() }
            } label: {
                Label("Navigator", systemImage: "sidebar.trailing")
            }
            .help("Show or hide files, PRs and info (⌥⌘0)")

            if store.selectedProject != nil, store.showsNavigator {
                Picker("", selection: Binding(
                    get: { store.navigatorTab },
                    set: { store.navigatorTab = $0 }
                )) {
                    ForEach(WorkspaceStore.NavigatorTab.allCases) { tab in
                        Label(tab.title, systemImage: tab.symbol)
                            .labelStyle(.iconOnly)
                            .help(tab.title)
                            .tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 150)
            }
        }
    }

    @ViewBuilder
    private var statusToast: some View {
        if let message = store.statusMessage {
            Text(message)
                .font(.callout)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .shadow(radius: 6, y: 2)
                .padding(.bottom, 40)
                .transition(.opacity)
                .task(id: message) {
                    try? await Task.sleep(for: .seconds(2.5))
                    store.statusMessage = nil
                }
        }
    }
}
