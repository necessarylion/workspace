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
    /// When this shell was last brought on screen, for the "recent" ordering.
    var lastUsedAt = Date()
    /// Called when the shell exits or ghostty asks to close the surface.
    @ObservationIgnored var onExit: (() -> Void)?
    @ObservationIgnored let view: GhosttySurfaceView
    private var hasStarted = false

    init(directory: URL, title: String) {
        self.directory = directory
        self.title = title
        self.view = GhosttySurfaceView()
        view.onTitleChange = { [weak self] title in
            self?.title = title
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
struct RecentTerminal: Identifiable {
    let session: TerminalSession
    let item: ViewerItem

    nonisolated var id: UUID { session.id }
}
