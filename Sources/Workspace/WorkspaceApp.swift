import SwiftUI

@main
struct WorkspaceApp: App {
    init() {
        // Before anything asks for a font: the list of installed faces is built
        // once and cached, and SF Mono has to be registered to be in it.
        SFMonoFont.register()
    }

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
            // Right under "About Workspace", where every Mac app keeps it.
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    AppUpdater.shared.check()
                    SettingsWindow.showUpdates()
                }
            }

            CommandGroup(replacing: .newItem) {
                Button("New Repository…") {
                    store.showNewRepository(.create)
                }
                .keyboardShortcut("n", modifiers: .command)

                Button("Clone Repository…") {
                    store.showNewRepository(.clone)
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])

                Divider()

                Button("Add Repository…") {
                    store.promptForProjectFolder()
                }
                .shortcut(.addRepository)
            }

            CommandGroup(after: .saveItem) {
                // Enabled whenever a file is open: menu items observe state
                // lazily, and saving a clean file is harmless.
                Button("Save") { store.saveCurrentDocument() }
                    .shortcut(.save)
                    .disabled(store.current?.document == nil)

                Button("Close") { store.closeCurrent() }
                    .shortcut(.close)
                    .disabled(store.current == nil)
            }

            CommandGroup(after: .sidebar) {
                Button(store.showsProjects ? "Hide Repositories" : "Show Repositories") {
                    store.showsProjects.toggle()
                }
                .shortcut(.toggleRepositories)

                Button(store.showsNavigator ? "Hide Navigator" : "Show Navigator") {
                    store.toggleNavigator()
                }
                .shortcut(.toggleNavigator)
            }

            CommandMenu("Go") {
                // A menu item rather than a shortcut on the palette itself: a
                // key equivalent is dispatched before the responder chain, so
                // ⌘P works even while the terminal — which answers every key
                // itself and passes none on — has the keyboard.
                Button("Go to File…") { store.toggleFileFinder() }
                    .shortcut(.goToFile)
                    .disabled(store.selectedProject == nil)

                Divider()

                Button("Back") { store.goBack() }
                    .shortcut(.goBack)
                    .disabled(!store.canGoBack)

                Button("Forward") { store.goForward() }
                    .shortcut(.goForward)
                    .disabled(!store.canGoForward)

                Divider()

                ForEach(WorkspaceStore.NavigatorTab.allCases) { tab in
                    Button(tab.title) { store.selectNavigatorTab(tab) }
                }
            }

            CommandMenu("Project") {
                Button("Refresh All") { store.refreshAll() }
                    .shortcut(.refreshAll)

                Divider()

                Button("Ask Claude") {
                    if let project = store.selectedProject {
                        store.openClaude(in: project)
                    }
                }
                .shortcut(.askClaude)
                .disabled(store.selectedProject == nil)

                Divider()

                Button("Open Terminal") {
                    if let project = store.selectedProject {
                        store.openTerminal(in: project)
                    }
                }
                .shortcut(.openTerminal)
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
                .shortcut(.toggleTerminal)

                // From inside a terminal this adds a tab next to it; from
                // anywhere else it starts one for the selected repository.
                Button("New Terminal Tab") {
                    if let item = store.current, item.isTerminal, !store.showsDashboard {
                        store.newTerminalTab(in: item)
                    } else if let project = store.selectedProject {
                        store.newTerminal(in: project)
                    }
                }
                .shortcut(.newTerminalTab)
                .disabled(store.selectedProject == nil)

                // Belongs to no repository, so it needs none selected.
                Button("New Terminal in Home") {
                    store.newGlobalTerminal()
                }
                .shortcut(.newHomeTerminal)

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
                .shortcut(.savePDF)
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
