import AppKit
import SwiftUI

/// The *Claude* tab of the navigator: the conversations running in this window,
/// then every conversation Claude Code has ever had about this repository.
///
/// Each one is a **terminal tab** running the real `claude`, which is what lets
/// several be under way at once — separate processes in separate shells, a turn
/// working away in one while another is typed into. This pane is the way back to
/// any of them, and the way to start one more.
///
/// The past ones come off disk rather than out of this window, so a session
/// started in a shell of your own is in the list too.
struct ClaudeSessionListView: View {
    @Environment(WorkspaceStore.self) private var store
    let project: Project

    @State private var sessions: [ClaudePastSession] = []
    @State private var isLoading = true

    /// The conversations this repository has running, whichever is on screen.
    private var live: [OpenTerminal] {
        store.runningClaudes(in: project)
    }

    /// Transcripts a running tab already has open. Their row belongs in the list
    /// above, so the disk list leaves them out rather than offering a second way
    /// in that would only send you back to the same shell.
    private var liveTranscriptIDs: Set<String> {
        Set(live.compactMap(\.session.claudeSessionID))
    }

    var body: some View {
        VStack(spacing: 0) {
            list
            Divider()
            footer
        }
        .task(id: project.id) { await load() }
        // A conversation started here writes its transcript the moment its first
        // prompt lands, so the list is read again whenever a tab comes or goes —
        // which is the cheapest signal there is that something happened.
        .task(id: live.count) { await load() }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                newChatRow

                if !live.isEmpty {
                    sectionHeader("Running")
                    ForEach(live) { terminal in
                        LiveClaudeRow(
                            terminal: terminal,
                            isOnScreen: store.isShowing(terminal),
                            open: { store.showTerminal(terminal) },
                            close: { store.closeTerminal(terminal) }
                        )
                    }
                }

                // Always drawn, whether or not anything is running above it: it
                // is the switch for the section below, and a switch that only
                // appears once a conversation is going would be unreachable
                // exactly when the list is nothing but history.
                pastHeader

                if store.showsPastClaudeConversations {
                    if isLoading && sessions.isEmpty {
                        HStack(spacing: 7) {
                            ProgressView().controlSize(.small)
                            Text("Reading past conversations…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                    } else if past.isEmpty {
                        Text(
                            sessions.isEmpty
                                ? "No conversations about this repository yet."
                                : "Every conversation on disk is already running."
                        )
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                    }

                    ForEach(past) { past in
                        ClaudeSessionRow(
                            past: past,
                            open: { store.resumeClaude(past, in: project) },
                            delete: { delete(past) }
                        )
                    }
                }
            }
            .padding(8)
        }
    }

    /// The Past heading, and the way to put the whole section away. The chevron
    /// turns and the count comes forward when it is closed, so a hidden list
    /// still says how much is behind it rather than looking like an empty one.
    private var pastHeader: some View {
        Button {
            store.showsPastClaudeConversations.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .rotationEffect(.degrees(store.showsPastClaudeConversations ? 90 : 0))
                Text("Past")
                    .textCase(.uppercase)
                if !store.showsPastClaudeConversations, !past.isEmpty {
                    Text("\(past.count)")
                        .monospacedDigit()
                }
                Spacer(minLength: 0)
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .help(
            store.showsPastClaudeConversations
                ? "Hide the conversations on disk"
                : "Show the conversations on disk"
        )
        .animation(.easeOut(duration: 0.15), value: store.showsPastClaudeConversations)
    }

    /// The conversations on disk that no running tab already has open.
    private var past: [ClaudePastSession] {
        let open = liveTranscriptIDs
        return sessions.filter { !open.contains($0.id) }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.tertiary)
            .textCase(.uppercase)
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 2)
    }

    /// Always at the top, whether or not one is already going. It starts another
    /// beside the ones already running rather than taking over one of them — two
    /// conversations about the same repository can be under way at once.
    private var newChatRow: some View {
        Button {
            store.openClaude(in: project)
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "square.and.pencil")
                    .font(.caption)
                Text("New Conversation")
                    .font(.callout)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .padding(.bottom, 4)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Text(sessions.count == 1 ? "1 conversation" : "\(sessions.count) conversations")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                Task { await load() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .help("Look for conversations again")
            .pointerCursor()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
    }

    /// To the Trash, so it can be taken back out — which is why it does not ask
    /// first, the same as deleting a file in the Files tab.
    private func delete(_ past: ClaudePastSession) {
        Task {
            if let error = await ClaudeSessionsIndex.delete(past) {
                store.showError("Could not delete the conversation — \(error)")
                return
            }
            sessions.removeAll { $0.id == past.id }
            store.showStatus("Conversation moved to the Trash")
        }
    }

    private func load() async {
        isLoading = true
        sessions = await ClaudeSessionsIndex.sessions(for: project.url)
        isLoading = false
    }
}

/// One conversation running in this window — a terminal tab with `claude` in it.
/// The row shows it; the ✕ under the pointer closes that tab alone, and the
/// others keep going.
private struct LiveClaudeRow: View {
    let terminal: OpenTerminal
    let isOnScreen: Bool
    let open: () -> Void
    let close: () -> Void

    @State private var isHovering = false

    /// The conversation's own name, read off its transcript — the same thing
    /// the Past rows are called, so one conversation reads the same whether it
    /// is running or over. Until its first prompt has landed there is nothing
    /// on disk to read, and the shell's own tab name stands in.
    private var title: String { terminal.session.displayTitle }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.callout)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            HStack(spacing: 5) {
                // The same wait the pane shows, said in a line: a conversation
                // opened and then left for another tab is still coming up, and
                // the row is the only place that says so.
                if terminal.session.isStartingClaude {
                    ProgressView().controlSize(.mini).scaleEffect(0.7).frame(width: 9, height: 9)
                    Text("starting…")
                } else if terminal.session.isWorking {
                    // The same thing the repository's card is badged with, said
                    // in a line: which of several conversations is the one
                    // still going.
                    ProgressView().controlSize(.mini).scaleEffect(0.7).frame(width: 9, height: 9)
                    Text(isOnScreen ? "working — on screen" : "working…")
                } else {
                    Image(systemName: "terminal")
                    Text(isOnScreen ? "on screen" : "running")
                }
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        // Floating, for the reason spelled out on ``ClaudeSessionRow``.
        .overlay(alignment: .topTrailing) {
            if isHovering {
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 16, height: 16)
                        .background(.regularMaterial, in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("End this conversation and close its tab")
                .pointerCursor()
                .padding(.top, 5)
                .padding(.trailing, 5)
            }
        }
        .background(
            isOnScreen
                ? AnyShapeStyle(.tint.opacity(0.16))
                : AnyShapeStyle(.quaternary.opacity(isHovering ? 0.3 : 0.16)),
            in: RoundedRectangle(cornerRadius: 7)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(isOnScreen ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear), lineWidth: 1)
        )
        .onHover { isHovering = $0 }
        .onTapGesture(perform: open)
        .pointerCursor()
        .help(title)
    }
}

/// One past conversation. The whole row resumes it in a terminal of its own; the
/// ✕ that appears under the pointer throws the transcript away.
private struct ClaudeSessionRow: View {
    let past: ClaudePastSession
    let open: () -> Void
    let delete: () -> Void

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(past.title)
                .font(.callout)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Text(past.modified.formatted(.relative(presentation: .named)))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        // Only under the pointer: a delete button on every row is a wall of
        // crosses down a list you are trying to read. It floats over the row
        // rather than sitting in it — in the flow it took width off the title
        // as it appeared, and a title that only just fitted re-wrapped onto a
        // second line under the pointer. Keeping a lane clear for it instead
        // left every row visibly short of its right edge, so it rides over the
        // text on a disc of its own.
        .overlay(alignment: .topTrailing) {
            if isHovering {
                Button(action: delete) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 16, height: 16)
                        .background(.regularMaterial, in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Move this conversation to the Trash")
                .pointerCursor()
                .padding(.top, 5)
                .padding(.trailing, 5)
            }
        }
        .background(
            .quaternary.opacity(isHovering ? 0.3 : 0.16),
            in: RoundedRectangle(cornerRadius: 7)
        )
        .onHover { isHovering = $0 }
        .onTapGesture(perform: open)
        .pointerCursor()
        .help(past.title)
        .contextMenu {
            Button("Resume in a Terminal", action: open)
            Button("Reveal Transcript in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([past.file])
            }
            Divider()
            Button("Move to Trash", action: delete)
        }
    }
}
