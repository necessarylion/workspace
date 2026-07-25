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
    func startIfNeeded(runningCommand command: String? = nil) {
        guard !hasStarted else { return }
        hasStarted = true
        view.start(directory: directory, initialInput: nil)

        guard let command else { return }
        // Give the shell a moment to draw its prompt before typing into it.
        Task {
            try? await Task.sleep(for: .milliseconds(700))
            self.send(command + "\n")
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
