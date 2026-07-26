import SwiftUI

/// The *Claude* tab of the navigator: every conversation Claude Code has had
/// about this repository, newest first.
///
/// They come off disk rather than out of this window, so a session started in a
/// shell is in the list too — and the one on screen is marked, so it is clear
/// which of them the composer below is typing into.
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

    var body: some View {
        VStack(spacing: 0) {
            list
            Divider()
            footer
        }
        .task(id: project.id) { await load() }
        // A conversation gets its file the moment it is given an id, so the
        // list catches up as soon as the first answer lands.
        .task(id: session?.claudeSessionID) { await load() }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                newChatRow

                if isLoading && sessions.isEmpty {
                    HStack(spacing: 7) {
                        ProgressView().controlSize(.small)
                        Text("Reading past conversations…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                } else if sessions.isEmpty {
                    Text("No conversations about this repository yet.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                }

                ForEach(sessions) { past in
                    ClaudeSessionRow(
                        past: past,
                        isCurrent: past.id == session?.claudeSessionID,
                        open: { open(past) },
                        delete: { delete(past) }
                    )
                }
            }
            .padding(8)
        }
    }

    /// Always at the top, whether or not a chat is open — it is both "start
    /// one" and "put this one aside and start again".
    private var newChatRow: some View {
        Button {
            let item = store.openClaudeChat(in: project)
            item.claude?.newChat()
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

    private func open(_ past: ClaudePastSession) {
        let item = store.openClaudeChat(in: project)
        guard let session = item.claude else { return }
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
            // The transcript that is on screen has just gone: what is left
            // cannot be resumed, so the chat starts over rather than sending
            // the next prompt to a session id that no longer exists.
            if let session, session.claudeSessionID == past.id {
                session.newChat()
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

/// One past conversation. The whole row opens it; the ✕ that appears under the
/// pointer throws it away.
private struct ClaudeSessionRow: View {
    let past: ClaudePastSession
    let isCurrent: Bool
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
                HStack(spacing: 5) {
                    Text(past.modified.formatted(.relative(presentation: .named)))
                    if isCurrent {
                        Text("· open")
                            .foregroundStyle(.tint)
                    }
                }
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
            .quaternary.opacity(isCurrent ? 0.45 : (isHovering ? 0.3 : 0.16)),
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
