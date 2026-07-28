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
    var runsClaude = false

    /// Which conversation on disk this tab is running. What stops a second
    /// `claude --resume` being started on the same transcript — and the name of
    /// the file ``claudeName`` is read out of.
    var claudeSessionID: String? {
        didSet { watchForClaudeName() }
    }

    /// What the conversation is about, read back from the transcript.
    ///
    /// `claude` names the terminal after *itself*, and "Claude Code" says
    /// nothing about which conversation this is when three of them are running
    /// side by side. The transcript already answers that, and it is the same
    /// answer the Past list shows, so a conversation is called one thing
    /// whether it is running or over.
    private(set) var claudeName: String?

    /// Whether ``claudeName`` is the name Claude Code chose for the
    /// conversation itself, rather than the first prompt standing in for it
    /// until that lands. Nothing to look for once it is true.
    @ObservationIgnored private var hasFinalClaudeName = false

    /// The name to put on this tab: the conversation, when there is one.
    var displayTitle: String { claudeName ?? title }

    /// The same name for somewhere outside the terminal — a Notification Centre
    /// banner — without Claude Code's state mark on the front. In the tab that
    /// mark is live and says something; on a banner it is one frame of a
    /// spinner, frozen, in front of the only words that matter.
    var notificationTitle: String {
        let name = displayTitle
        guard let first = name.unicodeScalars.first,
              (0x2800...0x28FF).contains(first.value) || first == "✳" else { return name }
        let stripped = String(name.dropFirst()).trimmingCharacters(in: .whitespaces)
        return stripped.isEmpty ? name : stripped
    }

    /// Whether the program in this tab is busy right now — for Claude Code,
    /// whether the conversation is mid-turn. See ``readsAsBusy(_:)`` for how
    /// that is known, and why the tab title is the only place it can be read.
    private(set) var isWorking = false

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
    /// Called when the program in this tab wants the user back, with the line
    /// to say. The store turns it into a Notification Centre banner.
    @ObservationIgnored var onAttention: ((String) -> Void)?
    /// When the last one went out, so a program that rings twice in a second
    /// does not put up two banners.
    @ObservationIgnored private var lastAttention = Date.distantPast
    @ObservationIgnored let view: GhosttySurfaceView
    private var hasStarted = false
    /// The look for ``claudeName``, while it is still going on.
    @ObservationIgnored private var nameWatch: Task<Void, Never>?

    /// Whether the shell behind this tab exists yet: a tab can be listed before
    /// anything is spawned, and only starts its shell when it is first shown.
    var isRunning: Bool { hasStarted }

    init(directory: URL, title: String) {
        self.directory = directory
        self.title = title
        self.view = GhosttySurfaceView()
        view.onTitleChange = { [weak self] title in
            guard let self else { return }
            let wasWorking = isWorking
            self.title = title
            isWorking = Self.readsAsBusy(title)
            titleChanges += 1
            // `claude` renames the tab as it starts work on a prompt, which is
            // exactly when a conversation that had no transcript may have got
            // one — so a rename is the cue to go looking again.
            watchForClaudeName()
            // The spinner going away is the turn ending: whatever was being
            // waited for is done, and the person who set it going is very
            // likely somewhere else by now.
            if wasWorking, !isWorking {
                raiseAttention("Finished — waiting for you")
            }
        }
        view.onClose = { [weak self] in
            self?.isWorking = false
            self?.onExit?()
        }
        // `claude` rings the bell when it needs an answer — a permission
        // prompt mid-turn, most of the time, which the title never mentions
        // because the spinner is still going.
        view.onBell = { [weak self] in
            self?.raiseAttention("Waiting for you")
        }
        view.onDesktopNotification = { [weak self] title, body in
            self?.raiseAttention(body.isEmpty ? (title ?? "Waiting for you") : body)
        }
    }

    /// Whether a tab title reads as "the program in here is busy".
    ///
    /// There is no other way to know. The app drives a real terminal, so the
    /// only thing that crosses back from `claude` is what it paints and what it
    /// names the tab — and it names the tab with a **state mark in front of the
    /// task**, which is exactly the state we want:
    ///
    /// ```
    /// ✳ Claude Code           idle, at the prompt
    /// ⠂ Claude Code           a turn is running
    /// ⠐ Say the word done     …still running, and now it knows the task
    /// ✳ Say the word done     the turn is over
    /// ```
    ///
    /// So a turn is running exactly while the first character is a braille
    /// spinner frame, and `✳` coming back is the turn ending. A shell that
    /// renames itself after the command it is running matches neither, which is
    /// what keeps this to the tabs it is meant for.
    static func readsAsBusy(_ title: String) -> Bool {
        guard let first = title.drop(while: \.isWhitespace).unicodeScalars.first else {
            return false
        }
        // The Braille Patterns block — every frame of the spinner is one of
        // these, and nothing else Claude Code puts there is.
        return (0x2800...0x28FF).contains(first.value)
    }

    /// Asks for a banner, unless something says now is not the moment.
    private func raiseAttention(_ body: String) {
        // A tab still coming up is not asking for anything: `claude` renames
        // the tab as it starts, and the cover is still over it either way.
        guard hasStarted, !isStartingClaude else { return }
        let now = Date()
        guard now.timeIntervalSince(lastAttention) > 3 else { return }
        lastAttention = now
        onAttention?(body)
    }

    /// Starts the shell (ghostty runs the user's configured shell itself),
    /// optionally typing a first command.
    ///
    /// `autoRun` false types the command and stops there, for the ones the user
    /// has to complete first — `bkt auth login` needs their own host.
    func startIfNeeded(runningCommand command: String? = nil, autoRun: Bool = true) {
        guard !hasStarted else { return }
        hasStarted = true
        // The first shell is where the system's permission dialog comes from:
        // right after something the user did, and never for someone who only
        // ever reads pull requests.
        TerminalNotifier.shared.prepare()
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

    /// Looks for the conversation's name until it finds the real one.
    ///
    /// It cannot simply be read when the tab opens: `claude` writes nothing
    /// until the **first prompt lands**, and that is however long the person
    /// takes to type it. So the file is asked for every couple of seconds, and
    /// after five minutes of nothing the look gives up rather than running for
    /// the life of the tab — a rename by the shell starts it over.
    ///
    /// The first prompt is only a stand-in: the CLI settles on a name of its
    /// own a moment later, and stopping at the stand-in would leave this tab
    /// called one thing while the same conversation is called another in the
    /// Past list. So the look carries on until that name lands.
    private func watchForClaudeName() {
        guard !hasFinalClaudeName, nameWatch == nil, let id = claudeSessionID else { return }
        nameWatch = Task { [weak self] in
            for attempt in 0..<150 {
                if attempt > 0 { try? await Task.sleep(for: .seconds(2)) }
                guard !Task.isCancelled, let self, !hasFinalClaudeName else { return }
                if let name = await ClaudeSessionsIndex.name(of: id, in: directory) {
                    claudeName = name.text
                    hasFinalClaudeName = name.isFinal
                    if name.isFinal {
                        nameWatch = nil
                        return
                    }
                }
            }
            // Left clear, so the next rename can start another look.
            self?.nameWatch = nil
        }
    }

    func terminate() {
        isWorking = false
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
