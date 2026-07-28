import AppKit
import SwiftUI

/// Making a repository from inside the app: an empty one, or a clone of one that
/// is already on GitHub or Bitbucket.
///
/// Both ways out are the same — the folder is added to the workspace and
/// selected — so the sheet only has to collect a name, somewhere to put it, and
/// for a clone the URL. The commands themselves are ``NewRepository``.
struct NewRepositorySheet: View {
    @Environment(WorkspaceStore.self) private var store

    let request: NewRepositoryRequest

    @State private var mode: NewRepository.Mode = .create
    @State private var name = ""
    @State private var remote = ""
    @State private var parent = FileManager.default.homeDirectoryForCurrentUser
    @State private var isWorking = false
    @State private var failure: String?

    /// The folder name the URL box last suggested. The field is only refilled
    /// while it still holds that suggestion, so a name typed by hand survives
    /// the next character pasted into the URL.
    @State private var suggestedName = ""

    @FocusState private var focus: Field?

    private enum Field { case remote, name }

    /// Where the last repository was put, so a second one does not need the
    /// picker again. In defaults rather than in the store: it is a preference of
    /// this sheet alone, and nothing else in the window reads it.
    @AppStorage("workspace.newRepositoryFolder") private var rememberedParent = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            modePicker
            fields
            landingLine
            if let failure {
                Text(failure)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            footer
        }
        .padding(18)
        .frame(width: 460)
        .onAppear {
            mode = request.mode
            parent = startingParent
            focus = request.mode == .clone ? .remote : .name
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("New Repository")
                .font(.headline)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var subtitle: String {
        switch mode {
        case .create:
            "An empty git repository in a new folder, added here straight away."
        case .clone:
            "Paste the SSH or HTTPS URL. The folder name comes from the URL — change it if you like."
        }
    }

    private var modePicker: some View {
        Picker("", selection: $mode) {
            ForEach(NewRepository.Mode.allCases) { mode in
                Text(mode.title).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .disabled(isWorking)
        .onChange(of: mode) { _, new in
            failure = nil
            focus = new == .clone ? .remote : .name
        }
    }

    private var fields: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 10) {
            if mode == .clone {
                GridRow {
                    Text("URL")
                        .foregroundStyle(.secondary)
                    TextField("git@github.com:owner/repo.git", text: $remote)
                        .textFieldStyle(.roundedBorder)
                        .focused($focus, equals: .remote)
                        .onChange(of: remote) { _, text in
                            let suggestion = NewRepository.folderName(forRemote: text)
                            if name == suggestedName { name = suggestion }
                            suggestedName = suggestion
                        }
                }
            }
            GridRow {
                Text(mode == .clone ? "Folder" : "Name")
                    .foregroundStyle(.secondary)
                    // Set here rather than on the URL row above, which is not
                    // always there to carry it.
                    .gridColumnAlignment(.trailing)
                TextField(mode == .clone ? "repo" : "my-project", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .focused($focus, equals: .name)
            }
            GridRow {
                Text("In")
                    .foregroundStyle(.secondary)
                location
            }
        }
        .disabled(isWorking)
    }

    private var location: some View {
        HStack(spacing: 8) {
            Text(shortened(parent))
                .lineLimit(1)
                .truncationMode(.head)
                .help(parent.path)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Choose…") { chooseParent() }
                .pointerCursor()
        }
    }

    /// Where it will end up, spelled out. The name and the folder are two fields
    /// apart, and this is the one line that says what they add up to.
    @ViewBuilder
    private var landingLine: some View {
        if !trimmedName.isEmpty {
            Text(shortened(parent.appending(path: trimmedName)))
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.head)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if isWorking {
                ProgressView().controlSize(.small)
                Text(mode.progressTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel") { store.dismissNewRepository() }
                .keyboardShortcut(.cancelAction)
                // A `git clone` cannot be called back once it has started, so
                // the way out is closed while one is running rather than
                // pretending the sheet can stop it.
                .disabled(isWorking)
                .pointerCursor(!isWorking)
            Button(mode.actionTitle) { submit() }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSubmit)
                .pointerCursor(canSubmit)
        }
    }

    // MARK: - Doing it

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSubmit: Bool {
        guard !isWorking, !trimmedName.isEmpty else { return false }
        return mode == .create || !NewRepository.normalizedRemote(remote).isEmpty
    }

    private func submit() {
        guard canSubmit else { return }
        isWorking = true
        failure = nil
        let mode = mode
        let name = trimmedName
        let parent = parent
        let remote = remote

        Task {
            do {
                let url = switch mode {
                case .create: try await NewRepository.create(named: name, in: parent)
                case .clone: try await NewRepository.clone(remote, named: name, into: parent)
                }
                rememberedParent = parent.path
                store.adoptNewRepository(at: url, cloned: mode == .clone)
            } catch {
                failure = error.localizedDescription
                isWorking = false
            }
        }
    }

    /// The remembered folder, then the one the added repositories share.
    private var startingParent: URL {
        var isDirectory: ObjCBool = false
        if !rememberedParent.isEmpty,
           FileManager.default.fileExists(atPath: rememberedParent, isDirectory: &isDirectory),
           isDirectory.boolValue {
            return URL(fileURLWithPath: rememberedParent)
        }
        return NewRepository.suggestedParent(near: store.projects.map(\.url))
    }

    private func chooseParent() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = parent
        panel.prompt = "Choose"
        panel.message = "Choose the folder to put the repository in."
        guard panel.runModal() == .OK, let chosen = panel.url else { return }
        parent = chosen
        failure = nil
    }

    /// `~` for the home folder, the way a prompt writes it.
    private func shortened(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = url.path
        guard path == home || path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }
}

/// The **+** the repositories pane, the folded rail and the empty states all
/// carry: the three ways a repository gets in, in one menu, so none of them is
/// only reachable from the main menu bar.
struct AddRepositoryMenu<Label: View>: View {
    @Environment(WorkspaceStore.self) private var store

    @ViewBuilder let label: () -> Label

    var body: some View {
        Menu {
            Button("New Repository…") { store.showNewRepository(.create) }
            Button("Clone Repository…") { store.showNewRepository(.clone) }
            Divider()
            Button("Add Existing Folder…") { store.promptForProjectFolder() }
        } label: {
            label()
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .pointerCursor()
    }
}
