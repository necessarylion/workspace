import AppKit
import SwiftUI

/// ⌘, — the command line tools the app runs, whether they are there, and the
/// two buttons that fix it when they are not.
///
/// Nothing is bundled and nothing is guessed: each row is what the tool itself
/// answered, through the same login shell every other command goes through.
struct SettingsView: View {
    @Environment(ToolInventory.self) private var tools

    /// The install or sign-in currently running in its own terminal.
    @State private var job: ToolConsoleJob?

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
                        ) { job = $0 }
                        if tool != RequiredTool.allCases.last {
                            Divider().padding(.leading, 42)
                        }
                    }
                }
            }

            Divider()
            footer
        }
        .frame(width: 580, height: 460)
        .task { await tools.refresh() }
        .sheet(item: $job) { job in
            ToolConsoleSheet(job: job) {
                Task { await tools.refresh(job.tool) }
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
    let run: (ToolConsoleJob) -> Void

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
                    Button("Install") { run(.install(tool)) }
                        .buttonStyle(.borderedProminent)
                        .pointerCursor()
                } else if let signIn = ToolConsoleJob.signIn(tool) {
                    // Signing in is the one thing left to do when a tool is
                    // there but logged out, so that case leads.
                    if state.needsSignIn {
                        Button("Sign In") { run(signIn) }
                            .buttonStyle(.borderedProminent)
                            .pointerCursor()
                    } else {
                        Button("Add Account") { run(signIn) }
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
