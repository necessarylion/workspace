import SwiftUI

/// The *Claude* tab of the navigator: the conversations open in this window,
/// then every conversation Claude Code has ever had about this repository.
///
/// The past ones come off disk rather than out of this window, so a session
/// started in a shell is in the list too — and the one on screen is marked, so
/// it is clear which of them the composer below is typing into.
struct ClaudeSessionListView: View {
    @Environment(WorkspaceStore.self) private var store
    let project: Project

    @State private var sessions: [ClaudePastSession] = []
    @State private var isLoading = true

    /// The chat this pane belongs to, if it is open. Nothing is started just by
    /// looking at the list.
    private var session: ClaudeSession? {
        store.claudeSession(for: project)
    }

    /// Every conversation running in this window, whether or not it is the one
    /// on screen — they answer at the same time, so the list has to show more
    /// than the one being typed into.
    private var live: [ClaudeSession] {
        store.claudeSessions(in: project)
    }

    /// Transcripts a live chat is already showing. Their row belongs in the open
    /// list above, so the disk list leaves them out rather than offering a
    /// second way in that would start a duplicate.
    private var liveTranscriptIDs: Set<String> {
        Set(live.compactMap(\.claudeSessionID))
    }

    var body: some View {
        VStack(spacing: 0) {
            list
            Divider()
            footer
        }
        .task(id: project.id) { await load() }
        // The id arrives with the `init` at the *top* of the first turn, before
        // the CLI has written a word of the transcript — so this catches a new
        // conversation existing, but not yet what it is called.
        //
        // Every open chat is watched, not just the one on screen: they answer at
        // the same time, and it is the one left running in the background whose
        // row would otherwise sit stale.
        .task(id: live.compactMap(\.claudeSessionID).joined(separator: ",")) { await load() }
        // …which is what this is for. By the time a turn ends the prompt is on
        // disk, so the row that was missing (or sitting there untitled) turns
        // into the real thing without anyone reaching for refresh.
        .onChange(of: live.map(\.isResponding)) { was, now in
            guard zip(was, now).contains(where: { $0 && !$1 }) else { return }
            Task { await load() }
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                newChatRow

                if !live.isEmpty {
                    sectionHeader("Open")
                    ForEach(live, id: \.id) { chat in
                        LiveClaudeRow(
                            session: chat,
                            isCurrent: chat.id == session?.id,
                            open: { store.selectClaudeChat(chat, in: project) },
                            close: { store.closeClaudeChat(chat, in: project) }
                        )
                    }
                    sectionHeader("Past")
                }

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
                            : "Every conversation on disk is already open."
                    )
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                }

                ForEach(past) { past in
                    ClaudeSessionRow(
                        past: past,
                        open: { open(past) },
                        delete: { delete(past) }
                    )
                }
            }
            .padding(8)
        }
    }

    /// The conversations on disk that no open chat is already showing.
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

    /// Always at the top, whether or not a chat is open. It starts another one
    /// beside the ones already running rather than clearing the one on screen —
    /// two conversations about the same repository can be under way at once.
    private var newChatRow: some View {
        Button {
            store.newClaudeChat(in: project)
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

    /// Resuming a transcript gets a chat of its own rather than taking over the
    /// one on screen — that chat may be mid-turn, and replacing its transcript
    /// under it would throw the answer away. A conversation already open is
    /// simply shown again.
    private func open(_ past: ClaudePastSession) {
        if let already = live.first(where: { $0.claudeSessionID == past.id }) {
            store.selectClaudeChat(already, in: project)
            return
        }
        // An untouched chat is worth reusing: it has nothing to lose, and
        // resuming into it saves leaving an empty one behind.
        let session = live.first { $0.isEmpty && !$0.isResponding }
            ?? store.newClaudeChat(in: project)
        store.selectClaudeChat(session, in: project)
        Task { await session.resume(past) }
    }

    /// To the Trash, so it can be taken back out — which is why it does not ask
    /// first, the same as deleting a file in the Files tab.
    private func delete(_ past: ClaudePastSession) {
        Task {
            if let error = await ClaudeSessionsIndex.delete(past) {
                store.showError("Could not delete the conversation — \(error)")
                return
            }
            // A transcript that is open has just gone: what is left cannot be
            // resumed, so that chat starts over rather than sending its next
            // prompt to a session id that no longer exists.
            for chat in live where chat.claudeSessionID == past.id {
                chat.newChat()
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

/// One conversation running in this window. The row shows it; the ✕ under the
/// pointer ends that one alone.
///
/// What it says under the title is whether the chat is working — the reason to
/// have more than one open is to leave a turn running and get on with another,
/// so "still answering" is the thing worth reading from here.
private struct LiveClaudeRow: View {
    let session: ClaudeSession
    let isCurrent: Bool
    let open: () -> Void
    let close: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            VStack(alignment: .leading, spacing: 3) {
                Text(session.displayTitle)
                    .font(.callout)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 5) {
                    if session.isResponding {
                        ProgressView().controlSize(.mini).scaleEffect(0.6).frame(width: 8, height: 8)
                        Text(session.activity ?? "Working…")
                            .foregroundStyle(.tint)
                    } else if isCurrent {
                        Text("on screen")
                    } else {
                        Text("open")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            }
            Spacer(minLength: 0)

            if isHovering {
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .padding(3)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("End this conversation")
                .pointerCursor()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(
            isCurrent ? AnyShapeStyle(.tint.opacity(0.16)) : AnyShapeStyle(.quaternary.opacity(isHovering ? 0.3 : 0.16)),
            in: RoundedRectangle(cornerRadius: 7)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear), lineWidth: 1)
        )
        .onHover { isHovering = $0 }
        .onTapGesture(perform: open)
        .pointerCursor()
        .help(session.displayTitle)
    }
}

/// One past conversation. The whole row opens it; the ✕ that appears under the
/// pointer throws it away.
private struct ClaudeSessionRow: View {
    let past: ClaudePastSession
    let open: () -> Void
    let delete: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            VStack(alignment: .leading, spacing: 3) {
                Text(past.title)
                    .font(.callout)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(past.modified.formatted(.relative(presentation: .named)))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)

            // Only under the pointer: a delete button on every row is a wall of
            // crosses down a list you are trying to read.
            if isHovering {
                Button(action: delete) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .padding(3)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Move this conversation to the Trash")
                .pointerCursor()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(
            .quaternary.opacity(isHovering ? 0.3 : 0.16),
            in: RoundedRectangle(cornerRadius: 7)
        )
        .onHover { isHovering = $0 }
        .onTapGesture(perform: open)
        .pointerCursor()
        .help(past.title)
        .contextMenu {
            Button("Open Conversation", action: open)
            Button("Reveal Transcript in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([past.file])
            }
            Divider()
            Button("Move to Trash", action: delete)
        }
    }
}
