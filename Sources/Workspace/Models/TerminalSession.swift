import Foundation

/// A live shell rooted in a project folder, running on libghostty.
///
/// The `GhosttySurfaceView` is created once and reused, so the running shell
/// survives SwiftUI re-rendering, tab switching and split changes.
@MainActor
@Observable
final class TerminalSession: Identifiable {
    nonisolated let id = UUID()
    nonisolated let directory: URL
    /// Live tab title — ghostty updates it from the shell (OSC 0/2).
    var title: String
    /// When this shell was last brought on screen. The lists keep a fixed
    /// order, so this only picks which shell a repository comes back to.
    var lastUsedAt = Date()

    /// Whether this tab was started to run `claude`. As many can be going at
    /// once as the repository has tabs — they are separate processes in
    /// separate shells — and the Claude tab lists exactly these, so a
    /// conversation left working in the background is one click away.
    ///
    /// Not saved with the tab: a restored tab has no process behind it yet, and
    /// listing it as a running conversation would be a lie.
    var runsClaude = false

    /// Which conversation on disk it resumed, when it resumed one. What stops a
    /// second `claude --resume` being started on the same transcript.
    var claudeSessionID: String?
    /// Called when the shell exits or ghostty asks to close the surface.
    @ObservationIgnored var onExit: (() -> Void)?
    /// Called when the shell renames the tab, so the saved list can keep up.
    @ObservationIgnored var onTitleChange: (() -> Void)?
    @ObservationIgnored let view: GhosttySurfaceView
    private var hasStarted = false

    /// Whether the shell behind this tab exists yet. A tab restored from the
    /// last run of the app is listed straight away but only starts its shell
    /// when it is first shown.
    var isRunning: Bool { hasStarted }

    init(directory: URL, title: String) {
        self.directory = directory
        self.title = title
        self.view = GhosttySurfaceView()
        view.onTitleChange = { [weak self] title in
            self?.title = title
            self?.onTitleChange?()
        }
        view.onClose = { [weak self] in
            self?.onExit?()
        }
    }

    /// Starts the shell (ghostty runs the user's configured shell itself),
    /// optionally typing a first command.
    ///
    /// `autoRun` false types the command and stops there, for the ones the user
    /// has to complete first — `bkt auth login` needs their own host.
    func startIfNeeded(runningCommand command: String? = nil, autoRun: Bool = true) {
        guard !hasStarted else { return }
        hasStarted = true
        view.start(directory: directory, initialInput: nil)

        guard let command else { return }
        run(command, autoRun: autoRun)
    }

    /// Types a command in once the shell is actually there to receive it.
    ///
    /// Separate from `startIfNeeded` because the command is not always known
    /// when the tab is made: starting Claude Code has to ask the CLI what it
    /// accepts first, and that question is answered while the shell is still
    /// drawing its prompt rather than before the tab appears.
    func run(_ command: String, autoRun: Bool = true) {
        Task {
            // The shell only exists once the view has a window — in a sheet that
            // takes noticeably longer than in a pane — and anything typed before
            // then is dropped.
            for _ in 0..<40 where !self.view.isLive {
                try? await Task.sleep(for: .milliseconds(50))
            }
            // Then give it a moment to draw its prompt.
            try? await Task.sleep(for: .milliseconds(700))
            self.send(autoRun ? command + "\n" : command)
        }
    }

    func send(_ text: String) {
        // A trailing newline means "run it". Pasted newlines don't execute
        // under bracketed paste; a real Enter keypress does.
        if text.hasSuffix("\n") {
            view.send(String(text.dropLast()))
            view.pressEnter()
        } else {
            view.send(text)
        }
    }

    func terminate() {
        view.close()
    }
}

/// One running shell together with the terminal item that holds it, so the
/// terminals list can show it and put it back on screen.
struct OpenTerminal: Identifiable {
    let session: TerminalSession
    let item: ViewerItem
    /// Its place among its own item's tabs, from 1. Shells in the same folder
    /// end up with the same name once the prompt renames them, so the list needs
    /// something to tell them apart by.
    let position: Int

    nonisolated var id: UUID { session.id }
}

/// Which folder a list of shells is about. A repository's shells and the ones
/// in the home folder are kept apart — one list, one scope.
enum TerminalScope: Equatable {
    case project(URL)
    case home
}
