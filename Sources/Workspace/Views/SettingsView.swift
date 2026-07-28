import AppKit
import CodeEditLanguages
import SwiftUI

/// ⌘, — the fonts code is shown in, the app's own updates, plus two lists of
/// programs the app runs but does not ship: the command line tools it needs,
/// and the language servers the editor starts.
///
/// Nothing in those two lists is guessed: every row is what the program itself
/// answered, through the same login shell every other command goes through.
struct SettingsView: View {
    private var updater: AppUpdater { .shared }

    enum Tab: Hashable {
        case appearance, requirements, servers, updates
    }

    @State private var tab: Tab = .appearance
    /// The last request for the Updates tab this view acted on, so the same one
    /// does not move the selection again every time the window is reopened.
    @State private var answeredRequest = 0

    var body: some View {
        TabView(selection: $tab) {
            FontSettings()
                .tabItem { Label("Appearance", systemImage: "paintpalette") }
                .tag(Tab.appearance)
            RequirementsSettings()
                .tabItem { Label("Requirements", systemImage: "wrench.and.screwdriver") }
                .tag(Tab.requirements)
            LanguageServerSettings()
                .tabItem { Label("Language Servers", systemImage: "chevron.left.forwardslash.chevron.right") }
                .tag(Tab.servers)
            UpdateSettings()
                .tabItem { Label("Updates", systemImage: "arrow.down.circle") }
                .tag(Tab.updates)
        }
        .frame(width: 620, height: 500)
        // "Check for Updates…" and the sidebar's badge both open this window
        // asking for one particular tab. Handled in two places because the ask
        // usually comes *before* this view exists, and sometimes after.
        .onAppear { answerUpdatesRequest() }
        .onChange(of: updater.updatesTabRequest) { answerUpdatesRequest() }
    }

    private func answerUpdatesRequest() {
        guard updater.updatesTabRequest != answeredRequest else { return }
        answeredRequest = updater.updatesTabRequest
        tab = .updates
    }
}

// MARK: - Fonts

/// The face and size the editor, the diff and the terminal use.
///
/// Every change lands straight away — the editor re-lays out, and libghostty is
/// handed a new configuration — so the preview under each section is the last
/// thing you need before deciding.
private struct FontSettings: View {
    /// Shared, like the catalog: `@Observable` tracks whatever this body reads.
    private var appearance: AppearanceSettings { .shared }

    /// What the previews are drawn with. Two lines, so the spacing between them
    /// is as visible as the face itself.
    private let sample = """
    let open = items.filter { $0.isOpen }
    print(open.count) // 42
    """

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Picker(
                        "Theme",
                        selection: Binding(
                            get: { appearance.palette.name },
                            set: { name in appearance.palette = SyntaxPalette.named(name) }
                        )
                    ) {
                        ForEach(SyntaxPalette.all, id: \.name) { palette in
                            Text(palette.name).tag(palette.name)
                        }
                    }
                    .pointerCursor()
                    themeSwatches
                } header: {
                    Text("Theme")
                } footer: {
                    Text("Colours for the editor, the diff and the terminal — a shell takes its background, its text and its sixteen ANSI colours from the theme too, and the ones already running change with it. The themes travel with the app, so a file looks the same on every Mac you run it on.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                Section {
                    FacePicker(
                        title: "Face",
                        selection: Binding(
                            get: { appearance.codeFontName },
                            set: { appearance.codeFontName = $0 }
                        )
                    )
                    SizeStepper(
                        title: "Editor size",
                        value: Binding(
                            get: { appearance.editorFontSize },
                            set: { appearance.editorFontSize = $0 }
                        )
                    )
                    SizeStepper(
                        title: "Diff size",
                        value: Binding(
                            get: { appearance.diffFontSize },
                            set: { appearance.diffFontSize = $0 }
                        )
                    )
                    LineHeightStepper(
                        value: Binding(
                            get: { appearance.editorLineHeight },
                            set: { appearance.editorLineHeight = $0 }
                        )
                    )
                    preview(
                        font: appearance.previewFont(named: appearance.codeFontName, size: appearance.editorFontSize),
                        size: appearance.editorFontSize,
                        lineHeight: appearance.editorLineHeight
                    )
                } header: {
                    Text("Code")
                } footer: {
                    Text("The editor, the diff and the terminal share a face, and a shell is drawn at the editor's size. A diff is read at a glance, so it keeps a size of its own; line spacing is the editor's alone.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

            }
            .formStyle(.grouped)

            Divider()
            footer
        }
    }

    /// The theme's own colours, on the theme's own background — quicker to
    /// judge than any name, and the only way to tell two dark themes apart.
    private var themeSwatches: some View {
        let palette = appearance.palette
        return HStack(spacing: 0) {
            ForEach(Self.swatchCaptures, id: \.self) { capture in
                Text(capture.token)
                    .font(appearance.previewFont(named: appearance.codeFontName, size: 11))
                    .foregroundStyle(Color(nsColor: palette.style(for: capture.capture)?.color ?? palette.foreground))
                    .padding(.trailing, 10)
            }
            Spacer()
        }
        .lineLimit(1)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(nsColor: palette.background ?? AppColors.viewerBackground),
            in: .rect(cornerRadius: 6)
        )
    }

    /// One word per colour the eye actually looks for in code.
    private static let swatchCaptures: [SwatchCapture] = [
        SwatchCapture(token: "import", capture: "include"),
        SwatchCapture(token: "class", capture: "storageclass"),
        SwatchCapture(token: "Type", capture: "type"),
        SwatchCapture(token: "call()", capture: "function"),
        SwatchCapture(token: "\"text\"", capture: "string"),
        SwatchCapture(token: "42", capture: "number"),
        SwatchCapture(token: "param", capture: "variable.parameter"),
        SwatchCapture(token: "// note", capture: "comment")
    ]

    struct SwatchCapture: Hashable {
        let token: String
        let capture: String
    }

    /// `lineHeight` is a multiple of the font's own height, the way the editor
    /// means it; SwiftUI wants the gap in points, which is the rest of it.
    private func preview(font: Font, size: Double, lineHeight: Double = 1) -> some View {
        Text(sample)
            .font(font)
            .lineSpacing(size * (lineHeight - 1))
            .lineLimit(2)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color(AppColors.viewerBackground), in: .rect(cornerRadius: 6))
            .foregroundStyle(.white.opacity(0.85))
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text("Only monospaced faces are listed — anything else would break the gutter and the diff columns.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            if appearance.isCustomised {
                Button("Restore Defaults") { appearance.restoreDefaults() }
                    .controlSize(.small)
                    .pointerCursor()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

/// The installed monospaced faces, each drawn in itself.
private struct FacePicker: View {
    let title: String
    /// What "no face chosen" is called.
    private let systemTitle = AppearanceSettings.systemFaceTitle
    @Binding var selection: String?

    var body: some View {
        Picker(title, selection: $selection) {
            Text(systemTitle)
                .font(.system(size: 12, design: .monospaced))
                .tag(String?.none)
            Divider()
            ForEach(AppearanceSettings.faces(including: selection), id: \.self) { face in
                // A face shown in itself needs no other description.
                Text(AppearanceSettings.isInstalled(face) ? face : "\(face) (not installed)")
                    .font(.custom(face, fixedSize: 12))
                    .tag(String?.some(face))
            }
        }
        .pointerCursor()
    }
}

/// Line spacing, as a multiple of the font's own height — the same number the
/// editor's paragraph style takes.
private struct LineHeightStepper: View {
    @Binding var value: Double

    var body: some View {
        Stepper(value: $value, in: AppearanceSettings.lineHeightRange, step: 0.05) {
            HStack {
                Text("Line spacing")
                Spacer()
                Text("×" + value.formatted(.number.precision(.fractionLength(2))))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .pointerCursor()
    }
}

/// A size in points, to the half point — the default editor size is 12.5.
private struct SizeStepper: View {
    let title: String
    @Binding var value: Double

    var body: some View {
        Stepper(value: $value, in: AppearanceSettings.sizeRange, step: 0.5) {
            HStack {
                Text(title)
                Spacer()
                Text(value.formatted(.number.precision(.fractionLength(0...1))) + " pt")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .pointerCursor()
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
    private var servers: ManagedLanguageServers { .shared }
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
                Text("Started as soon as you select a repository, for the languages actually in it.")
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
        VStack(alignment: .leading, spacing: 8) {
            automaticInstalls
            Divider()
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
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// The app's own copies: whether to fetch them, and how to be rid of them.
    private var automaticInstalls: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Toggle(
                    "Download missing servers automatically",
                    isOn: Binding(
                        get: { servers.consent == .allowed },
                        set: { servers.setConsent($0 ? .allowed : .denied) }
                    )
                )
                .toggleStyle(.checkbox)
                Text(
                    "Into the app's own folder, never into Homebrew, your global npm packages "
                        + "or your gems. The npm-published servers only — the rest keep the Install button above."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Remove Downloaded") {
                servers.removeAll()
                Task { await catalog.refresh() }
            }
            .controlSize(.small)
            .pointerCursor()
        }
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
        if ManagedLanguageServers.shared.installing.contains(entry.executable) {
            Pill(text: "downloading", color: .blue)
        } else if ManagedLanguageServers.shared.isInstalled(entry.executable) {
            // Worth saying apart from "ready": this one is the app's copy, and
            // Remove Downloaded is what takes it away rather than Homebrew.
            Pill(text: "downloaded", color: .green)
        } else {
            switch isInstalled {
            case true?: Pill(text: "ready", color: .green)
            case false?: Pill(text: "not installed", color: .orange)
            case nil: Pill(text: "checking", color: .secondary)
            }
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
