import SwiftUI

@main
struct WorkspaceApp: App {
    @State private var store = WorkspaceStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
        }
        .defaultSize(width: 1360, height: 860)
        // Compact toolbar without the "Workspace" title — the open item is
        // named by the viewer's own header row, so the title only wasted space.
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Repository…") {
                    store.promptForProjectFolder()
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            }

            CommandGroup(after: .saveItem) {
                // Enabled whenever a file is open: menu items observe state
                // lazily, and saving a clean file is harmless.
                Button("Save") { store.saveCurrentDocument() }
                    .keyboardShortcut("s")
                    .disabled(store.current?.document == nil)

                Button("Close") { store.closeCurrent() }
                    .keyboardShortcut("w", modifiers: [.command, .shift])
                    .disabled(store.current == nil)
            }

            CommandGroup(after: .sidebar) {
                Button(store.showsProjects ? "Hide Repositories" : "Show Repositories") {
                    store.showsProjects.toggle()
                }
                .keyboardShortcut("0", modifiers: .command)

                Button(store.showsNavigator ? "Hide Navigator" : "Show Navigator") {
                    store.showsNavigator.toggle()
                }
                .keyboardShortcut("0", modifiers: [.option, .command])
            }

            CommandMenu("Go") {
                Button("Back") { store.goBack() }
                    .keyboardShortcut("[", modifiers: .command)
                    .disabled(!store.canGoBack)

                Button("Forward") { store.goForward() }
                    .keyboardShortcut("]", modifiers: .command)
                    .disabled(!store.canGoForward)

                Divider()

                ForEach(WorkspaceStore.NavigatorTab.allCases) { tab in
                    Button(tab.title) { store.navigatorTab = tab }
                }
            }

            CommandMenu("Project") {
                Button("Refresh All") { store.refreshAll() }
                    .keyboardShortcut("r")

                Divider()

                Button("Open Terminal") {
                    if let project = store.selectedProject {
                        store.openTerminal(in: project)
                    }
                }
                .keyboardShortcut("t", modifiers: [.control, .command])
                .disabled(store.selectedProject == nil)

                Button("New Terminal Tab") {
                    if let item = store.current, case .terminal = item.kind {
                        store.newTerminalTab(in: item)
                    }
                }
                .keyboardShortcut("t")
                .disabled({
                    guard let item = store.current, case .terminal = item.kind else { return true }
                    return false
                }())

                Button("Open in VS Code") {
                    if let project = store.selectedProject {
                        store.openExternally(project, using: .vscode)
                    }
                }
                .disabled(store.selectedProject == nil)
            }

            CommandMenu("Editor") {
                Toggle("Wrap Lines", isOn: Binding(
                    get: { store.wrapsLines },
                    set: { store.wrapsLines = $0 }
                ))
                Toggle("Preview Markdown", isOn: Binding(
                    get: { store.markdownPreview },
                    set: { store.markdownPreview = $0 }
                ))
            }
        }
    }
}
