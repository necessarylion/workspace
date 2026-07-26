import SwiftUI

@main
struct WorkspaceApp: App {
    @State private var store = WorkspaceStore()
    /// Which external CLIs are installed and logged in. One instance for the
    /// whole app, so a sign-in done in Settings is what every window sees.
    @State private var tools = ToolInventory()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
                .environment(tools)
                // Every pane here is dense, and a scroller sliding in over a
                // file tree or a diff moves the content under the pointer.
                // Applied at the root, this reaches every scroll view and list
                // below it; the wheel, trackpad and keyboard still scroll.
                .scrollIndicators(.hidden)
        }
        .defaultSize(width: 1360, height: 860)
        // No title bar at all: the panes draw their own full-width header rows
        // and the window's would only add an empty band above them. The traffic
        // lights float over the leftmost pane, which leaves room for them.
        .windowStyle(.hiddenTitleBar)
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

                Button("Ask Claude") {
                    if let project = store.selectedProject {
                        store.openClaudeChat(in: project)
                    }
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .disabled(store.selectedProject == nil)

                Divider()

                Button("Open Terminal") {
                    if let project = store.selectedProject {
                        store.openTerminal(in: project)
                    }
                }
                .keyboardShortcut("t", modifiers: [.control, .command])
                .disabled(store.selectedProject == nil)

                // ⌃` the way editors do it: the same key in and back out. It
                // has to be a menu item — the terminal swallows plain keys, and
                // a key equivalent is dispatched before it ever sees them.
                Button(
                    store.current?.isTerminal == true && !store.showsDashboard
                        ? "Hide Terminal"
                        : "Show Terminal"
                ) {
                    store.toggleTerminal()
                }
                .keyboardShortcut("`", modifiers: .control)

                // From inside a terminal this adds a tab next to it; from
                // anywhere else it starts one for the selected repository.
                Button("New Terminal Tab") {
                    if let item = store.current, item.isTerminal, !store.showsDashboard {
                        store.newTerminalTab(in: item)
                    } else if let project = store.selectedProject {
                        store.newTerminal(in: project)
                    }
                }
                .keyboardShortcut("t")
                .disabled(store.selectedProject == nil)

                // Belongs to no repository, so it needs none selected.
                Button("New Terminal in Home") {
                    store.newGlobalTerminal()
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])

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
                // A draw.io file is drawn rather than edited by default, so
                // this one starts on: it is the way back to the XML.
                Toggle("Draw Diagrams", isOn: Binding(
                    get: { store.drawioPreview },
                    set: { store.drawioPreview = $0 }
                ))

                // The rendered document, not the file — so it only makes sense
                // for Markdown, and only Markdown offers it.
                Button("Save as PDF…") {
                    store.saveCurrentDocumentAsPDF()
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(store.visibleDocument?.isMarkdown != true)
            }
        }

        // ⌘, — the app menu's Settings item comes with this scene.
        Settings {
            SettingsView()
                .environment(tools)
                // Its own scene, so it needs the same root setting as the window.
                .scrollIndicators(.hidden)
        }
    }
}
