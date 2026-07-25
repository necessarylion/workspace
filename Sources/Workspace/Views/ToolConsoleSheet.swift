import SwiftUI

/// One install or one sign-in, waiting to be run in a terminal.
struct ToolConsoleJob: Identifiable {
    enum Kind {
        case install, signIn
    }

    let tool: RequiredTool
    let kind: Kind
    let command: String
    /// False for a command the user has to finish typing first.
    var autoRun = true

    var id: String { "\(tool.rawValue).\(kind == .install ? "install" : "signin")" }

    var title: String {
        switch kind {
        case .install: "Install \(tool.title)"
        case .signIn: "Sign in to \(tool.title)"
        }
    }

    var hint: String {
        if !autoRun {
            return "The host is filled in for Bitbucket Cloud — change it for a Data Center server, then press Return."
        }
        switch kind {
        case .install:
            return "Installing can take a few minutes. Close this when the prompt comes back."
        case .signIn:
            return "Answer the prompts here; the browser opens when the tool asks for it."
        }
    }

    static func install(_ tool: RequiredTool) -> ToolConsoleJob {
        ToolConsoleJob(tool: tool, kind: .install, command: tool.installCommand)
    }

    /// Nil for a tool with no sign-in of its own.
    static func signIn(_ tool: RequiredTool) -> ToolConsoleJob? {
        guard let signIn = tool.signIn else { return nil }
        return ToolConsoleJob(tool: tool, kind: .signIn, command: signIn.command, autoRun: signIn.autoRun)
    }
}

/// Runs an install or a sign-in in a real terminal.
///
/// Both are interactive — Homebrew streams progress, `gh auth login` asks
/// questions and waits for a keypress — so neither can go through `Shell.run`,
/// which has no TTY and nobody watching it. The same libghostty terminal the
/// repository panes use runs it instead, in the Settings window.
struct ToolConsoleSheet: View {
    let job: ToolConsoleJob
    /// Called on the way out, so Settings can re-check the tool.
    let onFinish: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var session: TerminalSession?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            terminal
            Divider()
            footer
        }
        .frame(width: 660, height: 440)
        .task { start() }
        .onDisappear {
            session?.terminate()
            onFinish()
        }
    }

    private var header: some View {
        HStack(spacing: 9) {
            ToolIcon(tool: job.tool, size: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(job.title)
                    .font(.headline)
                Text(job.command)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var terminal: some View {
        if let session {
            TerminalPaneView(session: session)
                .padding(.top, 8)
                .padding(.leading, 6)
                .background(Color(nsColor: AppColors.terminalBackground))
                // The NSView belongs to the session and cannot be swapped in
                // updateNSView, so it gets its own identity.
                .id(session.id)
        } else {
            Color(nsColor: AppColors.terminalBackground)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text(job.hint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            // No default-action shortcut: Return belongs to the shell.
            Button("Done") { dismiss() }
                .pointerCursor()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func start() {
        guard session == nil else { return }
        // Rooted at home: this has nothing to do with any repository.
        let session = TerminalSession(
            directory: URL(fileURLWithPath: NSHomeDirectory()),
            title: job.tool.executable
        )
        // Typing `exit` closes the sheet, like it closes a terminal tab.
        session.onExit = { dismiss() }
        session.startIfNeeded(runningCommand: job.command, autoRun: job.autoRun)
        self.session = session
    }
}

/// A tool's own logo where there is one, an SF Symbol where there is not.
struct ToolIcon: View {
    let tool: RequiredTool
    var size: CGFloat = 15

    var body: some View {
        if let brand = tool.brand, BrandArtwork.has(brand) {
            BrandMark(name: brand, size: size, color: .primary)
        } else {
            Image(systemName: tool.symbol)
                .font(.system(size: size - 2))
                .frame(width: size, height: size)
                .foregroundStyle(.secondary)
        }
    }
}
