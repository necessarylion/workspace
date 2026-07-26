import SwiftUI

/// One install or one sign-in, waiting to be run in a terminal.
struct ToolConsoleJob: Identifiable {
    enum Kind {
        case install, signIn
    }

    /// A required CLI has its own logo; a language server is just a binary.
    enum Icon {
        case tool(RequiredTool)
        case symbol(String)
    }

    let id: String
    let title: String
    let command: String
    let kind: Kind
    var icon: Icon = .symbol("terminal")
    /// Names the terminal tab, and is what the caller re-checks afterwards.
    var executable: String = ""
    /// False for a command the user has to finish typing first.
    var autoRun = true

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
        ToolConsoleJob(
            id: "\(tool.rawValue).install",
            title: "Install \(tool.title)",
            command: tool.installCommand,
            kind: .install,
            icon: .tool(tool),
            executable: tool.executable
        )
    }

    /// Nil for a tool with no sign-in of its own.
    static func signIn(_ tool: RequiredTool) -> ToolConsoleJob? {
        guard let signIn = tool.signIn else { return nil }
        return ToolConsoleJob(
            id: "\(tool.rawValue).signin",
            title: "Sign in to \(tool.title)",
            command: signIn.command,
            kind: .signIn,
            icon: .tool(tool),
            executable: tool.executable,
            autoRun: signIn.autoRun
        )
    }

    /// Nil for a server that arrives with a toolchain rather than a package
    /// manager, and so has nothing to run.
    static func install(server: LanguageServerEntry) -> ToolConsoleJob? {
        guard !server.installCommand.isEmpty else { return nil }
        return ToolConsoleJob(
            id: "lsp.\(server.language).install",
            title: "Install \(server.executable)",
            command: server.installCommand,
            kind: .install,
            icon: .symbol("chevron.left.forwardslash.chevron.right"),
            executable: server.executable
        )
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
            ToolIcon(icon: job.icon, size: 16)
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
            title: job.executable
        )
        // Typing `exit` closes the sheet, like it closes a terminal tab.
        session.onExit = { dismiss() }
        session.startIfNeeded(runningCommand: job.command, autoRun: job.autoRun)
        self.session = session
    }
}

/// A tool's own logo where there is one, an SF Symbol where there is not.
struct ToolIcon: View {
    let icon: ToolConsoleJob.Icon
    var size: CGFloat = 15

    init(icon: ToolConsoleJob.Icon, size: CGFloat = 15) {
        self.icon = icon
        self.size = size
    }

    init(tool: RequiredTool, size: CGFloat = 15) {
        self.icon = .tool(tool)
        self.size = size
    }

    var body: some View {
        switch icon {
        case .tool(let tool):
            if let brand = tool.brand, BrandArtwork.has(brand) {
                BrandMark(name: brand, size: size, color: .primary)
            } else {
                symbol(tool.symbol)
            }
        case .symbol(let name):
            symbol(name)
        }
    }

    private func symbol(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: size - 2))
            .frame(width: size, height: size)
            .foregroundStyle(.secondary)
    }
}
