import AppKit
import CodeEditLanguages
import SwiftUI

/// ⌘, — two lists of programs the app runs but does not ship: the command line
/// tools it needs, and the language servers the editor starts.
///
/// Nothing here is guessed: every row is what the program itself answered,
/// through the same login shell every other command goes through.
struct SettingsView: View {
    var body: some View {
        TabView {
            RequirementsSettings()
                .tabItem { Label("Requirements", systemImage: "wrench.and.screwdriver") }
            LanguageServerSettings()
                .tabItem { Label("Language Servers", systemImage: "chevron.left.forwardslash.chevron.right") }
        }
        .frame(width: 620, height: 500)
    }
}

// MARK: - Requirements

/// The command line tools the app runs, whether they are there, and the two
/// buttons that fix it when they are not.
private struct RequirementsSettings: View {
    @Environment(ToolInventory.self) private var tools

    /// The install or sign-in currently running in its own terminal.
    @State private var job: ToolConsoleJob?
    /// The tool that job belongs to, so only it is re-checked afterwards.
    @State private var jobTool: RequiredTool?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(RequiredTool.allCases) { tool in
                        ToolRow(
                            tool: tool,
                            state: tools.state(of: tool),
                            isChecking: tools.isChecking
                        ) { started, tool in
                            jobTool = tool
                            job = started
                        }
                        if tool != RequiredTool.allCases.last {
                            Divider().padding(.leading, 42)
                        }
                    }
                }
            }

            Divider()
            footer
        }
        .task { await tools.refresh() }
        .sheet(item: $job) { job in
            ToolConsoleSheet(job: job) {
                if let tool = jobTool {
                    Task { await tools.refresh(tool) }
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Command Line Tools")
                    .font(.headline)
                Text("Workspace drives these through your login shell — none of them ship with the app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button {
                Task { await tools.refresh() }
            } label: {
                if tools.isChecking {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Check Again", systemImage: "arrow.clockwise")
                }
            }
            .disabled(tools.isChecking)
            .pointerCursor(!tools.isChecking)
        }
        .padding(16)
    }

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 8) {
            if !tools.hasHomebrew, tools.unresolved.contains(where: \.needsHomebrew) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text("Homebrew is not installed, so those Install buttons cannot work yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Link("brew.sh", destination: URL(string: "https://brew.sh")!)
                    .font(.caption)
            } else {
                Text("Sign-ins are stored by the tools themselves, in your keychain.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

/// One tool: what it is for, what the check found, and what you can do about it.
private struct ToolRow: View {
    let tool: RequiredTool
    let state: ToolState?
    let isChecking: Bool
    let run: (ToolConsoleJob, RequiredTool) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            ToolIcon(tool: tool, size: 17)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(tool.title)
                        .font(.body.weight(.medium))
                    Text(tool.executable)
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                    pill
                }
                Text(tool.purpose)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                detail
            }

            Spacer(minLength: 8)
            actions
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var pill: some View {
        if let state {
            if !state.isInstalled {
                Pill(text: "not installed", color: tool.isEssential ? .red : .orange)
            } else if state.needsSignIn {
                Pill(text: "not signed in", color: .orange)
            } else {
                Pill(text: "ready", color: .green)
            }
        } else if isChecking {
            Pill(text: "checking", color: .secondary)
        }
    }

    /// The tool's own version line, and who it is logged in as — both worth
    /// seeing, because both are what the app's commands will use.
    @ViewBuilder
    private var detail: some View {
        if let state, state.isInstalled {
            VStack(alignment: .leading, spacing: 2) {
                if let version = state.version {
                    Text(version)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                switch state.account {
                case .signedIn(let who):
                    Text("Signed in as \(who)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                case .signedOut:
                    Text("No account — pull requests will fail until you sign in.")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                case .notNeeded:
                    EmptyView()
                }
            }
        }
    }

    @ViewBuilder
    private var actions: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if let state {
                if !state.isInstalled {
                    Button("Install") { run(.install(tool), tool) }
                        .buttonStyle(.borderedProminent)
                        .pointerCursor()
                } else if let signIn = ToolConsoleJob.signIn(tool) {
                    // Signing in is the one thing left to do when a tool is
                    // there but logged out, so that case leads.
                    if state.needsSignIn {
                        Button("Sign In") { run(signIn, tool) }
                            .buttonStyle(.borderedProminent)
                            .pointerCursor()
                    } else {
                        Button("Add Account") { run(signIn, tool) }
                            .buttonStyle(.bordered)
                            .pointerCursor()
                    }
                }
            }
            Link(destination: tool.homepage) {
                Text("Docs")
                    .font(.caption)
            }
            .pointerCursor()
        }
    }
}

// MARK: - Language servers

/// The servers the editor starts for completion, hover, jump-to-definition and
/// diagnostics — the built-in list, plus whatever the user adds.
private struct LanguageServerSettings: View {
    /// Read straight from the shared catalog: `@Observable` tracks whatever the
    /// body touches, so no copy of it has to be kept here.
    private var catalog: LanguageServerCatalog { .shared }
    /// The entry being added or edited in its own sheet.
    @State private var draft: ServerDraft?
    /// The install currently running in its own terminal.
    @State private var job: ToolConsoleJob?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(catalog.entries) { entry in
                        LanguageServerRow(
                            entry: entry,
                            isInstalled: catalog.installed[entry.executable],
                            isBuiltIn: catalog.isBuiltIn(entry),
                            isEdited: catalog.isEdited(entry),
                            install: { job = ToolConsoleJob.install(server: entry) },
                            edit: { draft = ServerDraft(entry: entry, isNew: false) },
                            restore: { catalog.restoreDefault(for: entry.language) },
                            delete: { catalog.delete(entry) }
                        )
                        if entry != catalog.entries.last {
                            Divider().padding(.leading, 16)
                        }
                    }
                }
            }

            Divider()
            footer
        }
        .task { await catalog.refresh() }
        .sheet(item: $draft) { draft in
            LanguageServerEditor(draft: draft) { catalog.save($0) }
        }
        .sheet(item: $job) { job in
            ToolConsoleSheet(job: job) {
                Task { await catalog.refresh(job.executable) }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Language Servers")
                    .font(.headline)
                Text("Started from your PATH the first time you open a file in that language.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button {
                Task { await catalog.refresh() }
            } label: {
                if catalog.isChecking {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Check Again", systemImage: "arrow.clockwise")
                }
            }
            .disabled(catalog.isChecking)
            .pointerCursor(!catalog.isChecking)

            Button {
                draft = ServerDraft.new(languages: catalog.languagesWithoutServer)
            } label: {
                Label("Add", systemImage: "plus")
            }
            .disabled(catalog.languagesWithoutServer.isEmpty)
            .pointerCursor(!catalog.languagesWithoutServer.isEmpty)
        }
        .padding(16)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text("A change takes effect the next time a file of that language is opened.")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
            if catalog.hasCustomisations {
                Button("Restore Defaults") { catalog.restoreAllDefaults() }
                    .controlSize(.small)
                    .pointerCursor()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

/// One language server: the language it serves, the command that starts it, and
/// whether that command is actually on this Mac.
private struct LanguageServerRow: View {
    let entry: LanguageServerEntry
    /// Nil until the first check has answered for this executable.
    let isInstalled: Bool?
    let isBuiltIn: Bool
    let isEdited: Bool
    let install: () -> Void
    let edit: () -> Void
    let restore: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(entry.languageName)
                        .font(.body.weight(.medium))
                    Text(entry.executable)
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                    pill
                    if !isBuiltIn {
                        Pill(text: "added", color: .blue)
                    } else if isEdited {
                        Pill(text: "edited", color: .blue)
                    }
                }
                Text(entry.command)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if isInstalled == false, entry.installCommand.isEmpty {
                    Text("Comes with its own toolchain — install that, then check again.")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }

            Spacer(minLength: 8)
            actions
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    @ViewBuilder
    private var pill: some View {
        switch isInstalled {
        case true?: Pill(text: "ready", color: .green)
        case false?: Pill(text: "not installed", color: .orange)
        case nil: Pill(text: "checking", color: .secondary)
        }
    }

    private var actions: some View {
        HStack(spacing: 6) {
            if isInstalled == false, !entry.installCommand.isEmpty {
                Button("Install", action: install)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .pointerCursor()
            }
            Menu {
                Button("Edit…", action: edit)
                if isEdited {
                    Button("Restore Default", action: restore)
                }
                Divider()
                Button(isBuiltIn ? "Remove" : "Delete", role: .destructive, action: delete)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 22)
            .pointerCursor()
        }
    }
}

/// An entry on its way in or back out of the catalog.
private struct ServerDraft: Identifiable {
    var entry: LanguageServerEntry
    /// New entries pick their language; existing ones cannot change it, since
    /// the language is what the catalog keys on.
    var isNew: Bool
    /// What the language picker offers — empty when editing.
    var languages: [CodeLanguage] = []

    var id: String { isNew ? "new" : entry.language }

    /// A blank entry for the first language that has no server yet.
    static func new(languages: [CodeLanguage]) -> ServerDraft? {
        guard let first = languages.first else { return nil }
        return ServerDraft(
            entry: LanguageServerEntry(
                language: first.id.rawValue,
                executable: "",
                command: "",
                languageID: first.tsName
            ),
            isNew: true,
            languages: languages
        )
    }
}

/// The form behind Add and Edit.
///
/// Every field is what the app will literally use: the executable is what it
/// looks for on PATH, the command is what the login shell runs, and the
/// language ID is what goes into every `textDocument/didOpen`.
private struct LanguageServerEditor: View {
    @State private var entry: LanguageServerEntry
    private let isNew: Bool
    private let save: (LanguageServerEntry) -> Void

    @Environment(\.dismiss) private var dismiss

    /// Only offered when adding: an existing entry is keyed by its language.
    private let languages: [CodeLanguage]

    init(draft: ServerDraft, save: @escaping (LanguageServerEntry) -> Void) {
        self._entry = State(initialValue: draft.entry)
        self.isNew = draft.isNew
        self.save = save
        self.languages = draft.languages
    }

    private var isValid: Bool {
        !entry.executable.trimmingCharacters(in: .whitespaces).isEmpty
            && !entry.command.trimmingCharacters(in: .whitespaces).isEmpty
            && !entry.languageID.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(isNew ? "Add Language Server" : "Edit \(entry.languageName)")
                .font(.headline)
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 12)

            Form {
                if isNew {
                    Picker("Language", selection: $entry.language) {
                        ForEach(languages, id: \.id.rawValue) { language in
                            Text(LanguageServerCatalog.name(of: language.id.rawValue))
                                .tag(language.id.rawValue)
                        }
                    }
                    .onChange(of: entry.language) { _, new in
                        // The tree-sitter name is the right guess for the LSP
                        // language ID often enough to be worth filling in.
                        entry.languageID = LanguageServerCatalog.codeLanguage(for: new)?.tsName ?? new
                    }
                }

                TextField("Executable", text: $entry.executable, prompt: Text("gopls"))
                    .help("The binary looked for on your PATH.")
                TextField("Command", text: $entry.command, prompt: Text("gopls serve"))
                    .help("Run through your login shell, with the repository as its working directory.")
                TextField("LSP Language ID", text: $entry.languageID, prompt: Text("go"))
                    .help("Sent with every document — servers reject the ones they do not recognise.")
                TextField("Install Command", text: $entry.installCommand, prompt: Text("optional"))
                    .help("What the Install button runs in a terminal. Leave empty when there is none.")
            }
            .formStyle(.grouped)
            .textFieldStyle(.roundedBorder)

            Divider()

            HStack {
                Text("The command runs through your login shell, so version managers are on PATH.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .pointerCursor()
                Button(isNew ? "Add" : "Save") {
                    var trimmed = entry
                    trimmed.executable = entry.executable.trimmingCharacters(in: .whitespaces)
                    trimmed.command = entry.command.trimmingCharacters(in: .whitespaces)
                    trimmed.languageID = entry.languageID.trimmingCharacters(in: .whitespaces)
                    trimmed.installCommand = entry.installCommand.trimmingCharacters(in: .whitespaces)
                    save(trimmed)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
                .pointerCursor(isValid)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 520)
    }
}
