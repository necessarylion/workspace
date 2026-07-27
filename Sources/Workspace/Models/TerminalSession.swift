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
    /// conversation left working in the background is one click away. The
    /// Terminals list leaves exactly these out in return, so a shell belongs to
    /// one list or the other and never to both.
    ///
    /// Not saved with the tab: a restored tab has no process behind it yet, and
    /// listing it as a running conversation would be a lie.
    var runsClaude = false

    /// Which conversation on disk this tab is running. What stops a second
    /// `claude --resume` being started on the same transcript — and the name of
    /// the file ``claudeName`` is read out of.
    var claudeSessionID: String? {
        didSet { watchForClaudeName() }
    }

    /// What the conversation is about — the first thing asked in it, read back
    /// from the transcript.
    ///
    /// `claude` names the terminal after *itself*, and "Claude Code" says
    /// nothing about which conversation this is when three of them are running
    /// side by side. The transcript already answers that, and it is the same
    /// answer the Past list shows, so a conversation is called one thing
    /// whether it is running or over.
    private(set) var claudeName: String?

    /// The name to put on this tab: the conversation, when there is one.
    var displayTitle: String { claudeName ?? title }

    /// Whether `claude` is still being got going in this tab.
    ///
    /// Starting a conversation is a few seconds of machinery: the shell has to
    /// spawn and draw a prompt, the CLI has to be asked which flags it takes,
    /// the command has to be typed, and `claude` takes a moment more to paint
    /// its first frame. None of that is what the person asked for — and a shell
    /// prompt is an invitation to type into a line the app is about to type
    /// into itself — so the pane covers it while it happens.
    private(set) var isStartingClaude = false

    /// How many times the shell has renamed itself. The cover watches this: a
    /// rename right after the command is typed is the shell announcing the
    /// program it just started, and the first sign of `claude` reaching this
    /// side of the terminal.
    @ObservationIgnored private var titleChanges = 0
    /// The wait that lifts the cover, so a second start cancels the first.
    @ObservationIgnored private var claudeStartupWatch: Task<Void, Never>?

    /// Called when the shell exits or ghostty asks to close the surface.
    @ObservationIgnored var onExit: (() -> Void)?
    /// Called when the shell renames the tab, so the saved list can keep up.
    @ObservationIgnored var onTitleChange: (() -> Void)?
    @ObservationIgnored let view: GhosttySurfaceView
    private var hasStarted = false
    /// The look for ``claudeName``, while it is still going on.
    @ObservationIgnored private var nameWatch: Task<Void, Never>?

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
            self?.titleChanges += 1
            self?.onTitleChange?()
            // `claude` renames the tab as it starts work on a prompt, which is
            // exactly when a conversation that had no transcript may have got
            // one — so a rename is the cue to go looking again.
            self?.watchForClaudeName()
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

    /// Types a command in once the shell is actually there to receive it,
    /// without waiting around for it to land.
    func run(_ command: String, autoRun: Bool = true) {
        Task { await type(command, autoRun: autoRun) }
    }

    /// The waiting itself, which ``runClaude`` needs to be able to await: it has
    /// something to do the moment the command has gone in.
    private func type(_ command: String, autoRun: Bool) async {
        // The shell only exists once the view has a window — in a sheet that
        // takes noticeably longer than in a pane — and anything typed before
        // then is dropped.
        for _ in 0..<40 where !view.isLive {
            try? await Task.sleep(for: .milliseconds(50))
        }
        // Then give it a moment to draw its prompt.
        try? await Task.sleep(for: .milliseconds(700))
        send(autoRun ? command + "\n" : command)
    }

    /// Puts the cover up, before it is even known what will be typed.
    ///
    /// Starting Claude Code asks the CLI which flags it takes, and the answer
    /// arrives a moment after the tab is already on screen. The cover goes up
    /// first so that moment is not a bare shell prompt.
    func beginClaudeStartup() {
        isStartingClaude = true
    }

    /// Types the command that starts `claude`, and takes the cover down once
    /// there is something behind it worth looking at.
    ///
    /// The only sign of `claude` this side of the terminal is the rename the
    /// shell does when it starts a program, so the wait is for that and then a
    /// beat more for the CLI to paint. A shell configured to rename nothing
    /// never sends one — hence the ceiling. The cover always comes down: a
    /// second of shell prompt is a far better failure than a spinner that stays
    /// for good.
    func runClaude(_ command: String) {
        isStartingClaude = true
        claudeStartupWatch?.cancel()
        claudeStartupWatch = Task { [weak self] in
            guard let self else { return }
            await type(command, autoRun: true)
            let renames = titleChanges
            for _ in 0..<25 where titleChanges == renames && !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
            }
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            isStartingClaude = false
            claudeStartupWatch = nil
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

    /// Looks for the conversation's name until it finds one.
    ///
    /// It cannot simply be read when the tab opens: `claude` writes nothing
    /// until the **first prompt lands**, and that is however long the person
    /// takes to type it. So the file is asked for every couple of seconds, and
    /// after five minutes of nothing the look gives up rather than running for
    /// the life of the tab — a rename by the shell starts it over.
    private func watchForClaudeName() {
        guard claudeName == nil, nameWatch == nil, let id = claudeSessionID else { return }
        nameWatch = Task { [weak self] in
            for attempt in 0..<150 {
                if attempt > 0 { try? await Task.sleep(for: .seconds(2)) }
                guard !Task.isCancelled, let self, claudeName == nil else { return }
                if let name = await ClaudeSessionsIndex.title(of: id, in: directory) {
                    claudeName = name
                    nameWatch = nil
                    return
                }
            }
            // Left clear, so the next rename can start another look.
            self?.nameWatch = nil
        }
    }

    func terminate() {
        nameWatch?.cancel()
        nameWatch = nil
        claudeStartupWatch?.cancel()
        claudeStartupWatch = nil
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
