import AppKit
import SwiftUI

/// The Claude Code chat, in the centre pane.
///
/// The transcript is above and the composer below, the way the editor
/// extensions lay it out: a box to type in, and under it the switchers that
/// decide who answers and what they are allowed to do.
struct ClaudeChatView: View {
    @Bindable var session: ClaudeSession
    let project: Project?

    @Environment(WorkspaceStore.self) private var store

    /// Where the scroll view parks itself as the reply grows.
    private let bottomAnchor = "claude-bottom"

    var body: some View {
        VStack(spacing: 0) {
            transcript
            Divider()
            ClaudeComposer(session: session) {
                store.closeCurrent()
            }
        }
        // A reply writes its file references as Markdown links, and their
        // addresses are repository paths, not web ones. Left to the default
        // action they go to Finder, which answers a path it cannot resolve with
        // a bare "-50" alert; anything naming a file in the project opens in
        // the editor instead, at the line the link asks for.
        .environment(\.openURL, OpenURLAction { url in
            if let (file, line) = Self.fileLink(url, root: project?.url) {
                store.openFile(file, revealLine: line)
                return .handled
            }
            // A real web address still goes to the browser. A path matching
            // nothing is dropped rather than handed on to be complained about.
            let scheme = url.scheme
            return scheme == nil || scheme == "file" ? .discarded : .systemAction
        })
    }

    /// A link that points at a file in the project, as that file's URL and the
    /// line its `#L42` fragment asks for. `nil` for a web address, or for a
    /// path this checkout does not have.
    private static func fileLink(_ url: URL, root: URL?) -> (URL, Int?)? {
        guard url.scheme == nil || url.scheme == "file" else { return nil }
        let path = url.path
        guard !path.isEmpty else { return nil }

        let file: URL
        if path.hasPrefix("/") {
            file = URL(fileURLWithPath: path)
        } else if path.hasPrefix("~") {
            file = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        } else if let root {
            file = root.appending(path: path)
        } else {
            return nil
        }

        // A folder is a navigator matter, not something the editor can show.
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory),
              !isDirectory.boolValue
        else { return nil }

        // `#L42`, and also the `#L42-L51` a range gets written as — the first
        // number in the fragment is the line to scroll to either way. It is
        // written the way the gutter shows it, counted from 1, and `revealLine`
        // counts from 0.
        let line = url.fragment.flatMap {
            Int($0.drop { !$0.isNumber }.prefix { $0.isNumber })
        }
        return (file, line.map { max($0 - 1, 0) })
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if session.isEmpty {
                        ClaudeChatWelcome(session: session, project: project)
                    }
                    ForEach(session.messages) { message in
                        ClaudeMessageView(
                            message: message,
                            // Only the reply at the bottom, and only once it has
                            // finished being written: the options belong to the
                            // question actually waiting to be answered.
                            offersQuickReplies: message.id == session.messages.last?.id
                                && !session.isResponding,
                            openFile: { path in store.openFile(URL(fileURLWithPath: path)) },
                            answer: answer
                        )
                    }
                    if session.isStarting {
                        statusLine("Starting Claude Code…")
                    } else if session.isResponding, !isWriting {
                        statusLine(session.activity.map(Self.activityTitle) ?? "Working…")
                    }
                    if let error = session.lastError {
                        errorNotice(error)
                    }
                    Color.clear
                        .frame(height: 1)
                        .id(bottomAnchor)
                }
                .frame(maxWidth: 760, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity, alignment: .top)
            }
            // Two signals, because a reply grows in two ways: a new message or
            // a new tool row, and the text of the one being written.
            .onChange(of: session.messages.count) { scrollDown(proxy) }
            .onChange(of: tailLength) { scrollDown(proxy) }
            .onChange(of: session.isResponding) { scrollDown(proxy) }
        }
        .textSelection(.enabled)
    }

    private func scrollDown(_ proxy: ScrollViewProxy) {
        proxy.scrollTo(bottomAnchor, anchor: .bottom)
    }

    /// A clicked option. It goes straight off when there is nothing half
    /// written — that is the whole point of a one-click answer — but a box that
    /// has something in it is never overwritten: the choice joins what is there
    /// and waits for ⏎, so a click can't lose a sentence you were typing.
    private func answer(_ reply: ClaudeQuickReply) {
        if session.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            session.draft = reply.text
            Task { await session.send() }
        } else {
            session.draft += (session.draft.hasSuffix(" ") ? "" : " ") + reply.text
        }
    }

    /// How much has been written into the last message so far. Only the tail is
    /// measured: everything above it has stopped changing.
    ///
    /// Counted in UTF-8 bytes rather than characters. `String.count` walks the
    /// whole string to group it into graphemes, and this is read on every pass
    /// of the transcript's body while a reply is streaming — so a long answer
    /// would be re-measured end to end per token. Any number that moves when
    /// text arrives will do, and this one is free.
    private var tailLength: Int {
        session.messages.last?.blocks.reduce(0) { total, block in
            switch block {
            case .text(let text), .thinking(let text): total + text.text.utf8.count
            case .tool(let call): total + call.partialInput.utf8.count + (call.result?.utf8.count ?? 0)
            }
        } ?? 0
    }

    /// Whether text is arriving right now, so the spinner does not sit under a
    /// paragraph that is already being written.
    private var isWriting: Bool {
        session.messages.last?.isStreaming == true
    }

    private func statusLine(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private func errorNotice(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(text)
                .font(.callout)
                .textSelection(.enabled)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    /// The CLI's one-word status, in words worth reading.
    private static func activityTitle(_ status: String) -> String {
        switch status {
        case "requesting": "Thinking…"
        case "tool_use", "tool_running": "Running a tool…"
        default: status.replacingOccurrences(of: "_", with: " ").capitalized + "…"
        }
    }
}

// MARK: - Empty state

private struct ClaudeChatWelcome: View {
    let session: ClaudeSession
    let project: Project?

    private var suggestions: [String] {
        [
            "What does this repository do?",
            "Explain the changes I have not committed yet",
            "Find where the terminal is started and walk me through it",
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                ClaudeMark(size: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Claude Code")
                        .font(.title3.weight(.semibold))
                    Text(project?.name ?? session.directory.lastPathComponent)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Text("Ask about this repository. Claude reads and edits the files in it, runs commands, and answers here.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(suggestions, id: \.self) { suggestion in
                    Button {
                        session.draft = suggestion
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "sparkle")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                            Text(suggestion)
                                .font(.callout)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .background(.quaternary.opacity(0.22), in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                }
            }
            .padding(.top, 2)
        }
        .padding(.bottom, 8)
    }
}

/// Claude's own mark, drawn from artwork we ship rather than borrowed from the
/// desktop app's icon — the CLI is what this pane drives, and that does not
/// mean the desktop app is installed. The resource is the whole tile, mark and
/// terracotta together, so nothing about the artwork is reconstructed here.
struct ClaudeMark: View {
    var size: CGFloat = 15

    /// The radius the tile is rounded by, as a fraction of its side — macOS'
    /// own app-icon proportion, because the mark sits beside real app icons.
    private static let cornerFraction: CGFloat = 0.225

    /// Read once, by URL like every other resource here rather than through
    /// `Image(_:bundle:)`: on macOS that initialiser resolves a name against an
    /// asset catalogue, and a file copied in by `.process` is a loose one, so
    /// it comes back empty rather than failing. The artwork stays an SVG —
    /// AppKit keeps it as a vector rep, which is what lets one 2 KB file serve
    /// every size below without a set of bitmaps.
    ///
    /// The corners are rounded into the image rather than clipped in the view:
    /// one of these is a segment of a segmented `Picker`, and that flattens a
    /// segment's label down to a plain image, losing any shape clipped around
    /// it. Drawing through a handler keeps the rounding vector too — it runs
    /// again at whatever resolution the image is asked to rasterise at.
    ///
    /// `isTemplate` is forced off because a template is filled with the accent
    /// colour, and two of these sit inside buttons where that is not the
    /// default one.
    @MainActor private static let artwork: NSImage? = {
        guard let url = Bundle.module.url(forResource: "claude-mark", withExtension: "svg"),
              let source = NSImage(contentsOf: url) else { return nil }
        let rounded = NSImage(size: source.size, flipped: false) { rect in
            NSBezierPath(
                roundedRect: rect,
                xRadius: rect.width * cornerFraction,
                yRadius: rect.height * cornerFraction
            ).addClip()
            source.draw(in: rect)
            return true
        }
        rounded.isTemplate = false
        return rounded
    }()

    var body: some View {
        Group {
            if let artwork = Self.artwork {
                Image(nsImage: artwork)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                // Shipped artwork cannot go missing in a built app, but a mark
                // that silently renders as nothing is not worth the risk. Only
                // this branch is clipped — the artwork carries its own corners.
                Color(red: 0.851, green: 0.467, blue: 0.341)
                    .clipShape(RoundedRectangle(cornerRadius: size * Self.cornerFraction))
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - One message

private struct ClaudeMessageView: View {
    @Bindable var message: ClaudeMessage
    /// Whether this is the reply whose options are worth drawing as buttons.
    var offersQuickReplies = false
    /// Opens a file a tool touched, in the editor next door.
    let openFile: (String) -> Void
    let answer: (ClaudeQuickReply) -> Void

    /// The choices this reply ends with, when it ends with a question that has
    /// any — see ``ClaudeQuickReplies``, which is deliberately hard to trigger.
    private var quickReplies: [ClaudeQuickReply] {
        guard offersQuickReplies, !message.isStreaming else { return [] }
        return ClaudeQuickReplies.read(from: message.plainText)
    }

    var body: some View {
        switch message.role {
        case .user: userMessage
        case .assistant: assistantMessage
        case .note: note
        }
    }

    private var userMessage: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(message.blocks) { block in
                if case .text(let text) = block, !text.text.isEmpty {
                    Text(text.text)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !message.attachments.isEmpty {
                HStack(spacing: 6) {
                    ForEach(message.attachments, id: \.self) { url in
                        AttachmentChip(name: url.lastPathComponent)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    /// No mark down the side of the reply: the whole pane is Claude, and one
    /// per message is a column of the same icon repeating past what it says.
    /// The box around a prompt is what tells the two sides apart.
    private var assistantMessage: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(message.blocks) { block in
                switch block {
                case .text(let text):
                    if !text.text.isEmpty {
                        // Markdown only once the paragraph has stopped moving:
                        // re-parsing it on every token arriving is work nobody
                        // sees.
                        if message.isStreaming {
                            Text(text.text)
                                .font(.callout)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            MarkdownText(text: text.text)
                                .font(.callout)
                        }
                    }
                case .thinking(let text):
                    ThinkingRow(text: text)
                case .tool(let call):
                    ClaudeToolRow(call: call, openFile: openFile)
                }
            }
            if !quickReplies.isEmpty {
                ClaudeQuickReplyRow(replies: quickReplies, answer: answer)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var note: some View {
        HStack(spacing: 7) {
            Image(systemName: "info.circle")
                .font(.caption)
            Text(message.plainText)
                .font(.caption)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.tertiary)
    }
}

/// The options a question ended with, as buttons.
///
/// Full-width rows rather than a line of pills: an option is a phrase, not a
/// word, and the row keeps its number so the list still reads against the one
/// written above it — clicking row 2 and typing "2" are the same answer.
private struct ClaudeQuickReplyRow: View {
    let replies: [ClaudeQuickReply]
    let answer: (ClaudeQuickReply) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(replies) { reply in
                ClaudeQuickReplyButton(reply: reply) { answer(reply) }
            }
        }
    }
}

private struct ClaudeQuickReplyButton: View {
    let reply: ClaudeQuickReply
    let answer: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: answer) {
            HStack(spacing: 8) {
                Text("\(reply.number)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
                Text(reply.text)
                    .font(.callout)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                .quaternary.opacity(isHovering ? 0.4 : 0.22),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(.tint.opacity(isHovering ? 0.5 : 0), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .pointerCursor()
        .help("Answer with “\(reply.text)”")
    }
}

/// What Claude thought before answering. Folded away — it is context, not the
/// answer — and one click opens it.
private struct ThinkingRow: View {
    @Bindable var text: ClaudeTextBlock
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.14)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "brain")
                    Text("Thinking")
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerCursor()

            if isExpanded {
                Text(text.text)
                    .font(.caption)
                    .italic()
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 18)
            }
        }
    }
}

/// One tool call: a row that says what ran, and unfolds into what it was given
/// and what came back.
private struct ClaudeToolRow: View {
    @Bindable var call: ClaudeToolCall
    let openFile: (String) -> Void

    /// A tool can return a whole file; the row shows the head of it and says so.
    private let resultLineLimit = 24

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if call.isExpanded {
                details
            }
        }
        .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(call.isError ? .red.opacity(0.4) : .clear, lineWidth: 1)
        }
    }

    private var header: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.14)) { call.isExpanded.toggle() }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: call.symbol)
                    .font(.caption)
                    .foregroundStyle(call.isError ? .red : .secondary)
                    .frame(width: 14)
                Text(call.name)
                    .font(.caption.weight(.medium))
                if !summary.isEmpty {
                    Text(summary)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 4)
                if call.isRunning {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                } else {
                    Image(systemName: call.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    /// The first line only: a heredoc or a long prompt would otherwise push the
    /// row's own name off the side.
    private var summary: String {
        call.summary.split(separator: "\n").first.map(String.init) ?? ""
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            if let arguments = argumentText, !arguments.isEmpty {
                block(title: "Input", text: arguments)
            }
            if let result = call.result, !result.isEmpty {
                block(title: call.isError ? "Error" : "Result", text: result)
            }
            if let path = openablePath {
                Button {
                    openFile(path)
                } label: {
                    Label("Open \((path as NSString).lastPathComponent)", systemImage: "arrow.up.forward.square")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .pointerCursor()
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 9)
    }

    /// What the tool was called with — the confirmed arguments once they are
    /// parsed, and the half-written JSON while they are still arriving.
    private var argumentText: String? {
        if case .object(let fields) = call.input, !fields.isEmpty {
            return fields
                .sorted { $0.key < $1.key }
                .map { "\($0.key): \($0.value.displayText)" }
                .joined(separator: "\n")
        }
        return call.partialInput.isEmpty ? nil : call.partialInput
    }

    /// The file this call is about, when it is about one, so the row can open it
    /// in the editor next door.
    private var openablePath: String? {
        guard let path = call.input["file_path"]?.stringValue ?? call.input["path"]?.stringValue,
              FileManager.default.fileExists(atPath: path) else { return nil }
        return path
    }

    private func block(title: String, text: String) -> some View {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let shown = lines.prefix(resultLineLimit).joined(separator: "\n")
        let hidden = max(0, lines.count - resultLineLimit)

        return VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(shown)
                    .font(.caption.monospaced())
                    .foregroundStyle(title == "Error" ? .red : .secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if hidden > 0 {
                Text("\(hidden) more lines")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Composer

private struct ClaudeComposer: View {
    @Bindable var session: ClaudeSession
    /// What ⎋ does: the same as the ✕ in the header — leave the chat. The
    /// conversation keeps running behind it, the way a terminal does.
    let close: () -> Void

    @State private var inputHeight = ChatInputField.singleLineHeight
    @State private var caret = 0
    @State private var selectedCompletion = 0
    /// The token ⎋ was pressed on, so the list stays shut until the caret moves
    /// somewhere else rather than springing back on the next keystroke.
    @State private var dismissedToken: ChatCompletionToken?
    /// The menu as it stands. Held rather than computed, because ranking a
    /// repository's worth of paths is not work a keystroke can do on the way to
    /// the screen — see ``refreshCompletions``.
    @State private var completions: [ChatCompletion] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !session.attachments.isEmpty {
                attachmentRow
            }
            if !completions.isEmpty {
                ChatCompletionList(
                    completions: completions,
                    selected: selectedCompletion,
                    accept: accept
                )
            }
            input
            controls
        }
        .padding(12)
        .background(.bar)
        // A different token means a different list, so the highlight goes back
        // to the top rather than staying on the fourth row of the last one.
        .onChange(of: token) { selectedCompletion = 0 }
        // Keyed on the file list as well as the token: what was typed before it
        // finished loading had nothing to match against, and this is what asks
        // again the moment there is something.
        .task(id: CompletionRequest(token: token, files: session.projectFiles.count)) {
            await refreshCompletions()
        }
        .task { await session.loadCompletions() }
    }

    // MARK: - Completions

    /// What the menu is currently an answer to. A change in either half is a
    /// reason to work it out again; nothing else is.
    private struct CompletionRequest: Equatable {
        let token: ChatCompletionToken?
        let files: Int
    }

    private var token: ChatCompletionToken? {
        let found = ChatCompletionToken.read(in: session.draft, caret: caret)
        return found == dismissedToken ? nil : found
    }

    /// Works out the menu for what is under the caret.
    ///
    /// The file half is awaited rather than computed inline: it compares the
    /// query against every path in the repository, which is tens of thousands
    /// of them, and doing that on the main actor is felt in the box being typed
    /// into. `.task(id:)` cancels the one in flight when another letter lands,
    /// so only the last query's list is ever shown.
    private func refreshCompletions() async {
        guard let token else {
            completions = []
            return
        }
        switch token.kind {
        case .command:
            // A handful of names — nothing worth leaving the main actor for.
            completions = commandCompletions(token.query)
        case .file:
            let found = await fileCompletions(token.query)
            guard !Task.isCancelled else { return }
            completions = found
        }
    }

    private func commandCompletions(_ query: String) -> [ChatCompletion] {
        let needle = query.lowercased()
        return session.slashCommands
            .filter { needle.isEmpty || $0.name.lowercased().contains(needle) }
            // What starts with what you typed comes first; `/re` should reach
            // "review" before "code-review:code-review".
            .sorted {
                let first = $0.name.lowercased().hasPrefix(needle)
                let second = $1.name.lowercased().hasPrefix(needle)
                return first == second ? $0.name < $1.name : first
            }
            .prefix(10)
            .map { command in
                ChatCompletion(
                    id: "cmd:" + command.name,
                    insert: "/" + command.name,
                    title: "/" + command.name,
                    detail: command.detail,
                    symbol: symbol(for: command.source)
                )
            }
    }

    private func symbol(for source: ClaudeSlashCommand.Source) -> String {
        switch source {
        case .project: "folder.badge.gearshape"
        case .user: "person.crop.circle"
        case .builtIn: "terminal"
        }
    }

    private func fileCompletions(_ query: String) async -> [ChatCompletion] {
        let index = session.projectFiles
        // A bare `@` has nothing to rank by, so it opens on the first few paths
        // rather than on an empty box — enough to show the menu is there.
        let matches = query.isEmpty
            ? index.paths.prefix(10).map { FileFinder.Match(path: $0, highlighted: []) }
            : await FileFinder.search(query, in: index, limit: 10)

        return matches.map { match in
            ChatCompletion(
                id: "file:" + match.path,
                insert: "@" + match.path,
                title: match.name,
                symbol: FileIcon.symbol(for: URL(fileURLWithPath: match.path)),
                trailing: match.folder
            )
        }
    }

    /// Puts the completion in place of what was typed, and leaves a space after
    /// it so the next word does not run into the path.
    private func accept(_ completion: ChatCompletion) {
        guard let token else { return }
        let text = session.draft
        let start = String.Index(utf16Offset: token.start, in: text)
        let end = String.Index(utf16Offset: min(caret, text.utf16.count), in: text)
        guard start <= end, end <= text.endIndex else { return }

        let replacement = completion.insert + " "
        session.draft = text.replacingCharacters(in: start..<end, with: replacement)
        caret = token.start + replacement.utf16.count
        dismissedToken = nil
        selectedCompletion = 0
    }

    /// ↑ ↓ ⏎ ⇥ ⎋, when a list is up. Returning false lets the box have them.
    private func handle(_ key: ChatCompletionKey) -> Bool {
        let rows = completions
        guard !rows.isEmpty else { return false }
        switch key {
        case .up:
            selectedCompletion = max(0, selectedCompletion - 1)
        case .down:
            selectedCompletion = min(rows.count - 1, selectedCompletion + 1)
        case .accept:
            accept(rows[min(selectedCompletion, rows.count - 1)])
        case .dismiss:
            dismissedToken = token
        }
        return true
    }

    private var attachmentRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(session.attachments, id: \.self) { url in
                    AttachmentChip(name: session.displayPath(of: url)) {
                        session.removeAttachment(url)
                    }
                }
            }
        }
    }

    /// One line to start with; the field itself says when it needs more.
    private var input: some View {
        ChatInputField(
            text: $session.draft,
            height: $inputHeight,
            caret: $caret,
            placeholder: "Ask Claude about this repository…  / for commands, @ for files",
            onSubmit: {
                guard session.canSend else { return }
                Task { await session.send() }
            },
            // The box has the keyboard, so ⎋ never reaches the viewer's own
            // handler — see `EscapeKey` — and it has to close the chat here
            // instead, which is what ⎋ does everywhere else in the window.
            onEscape: close,
            onCompletionKey: handle
        )
        .frame(height: inputHeight)
        .padding(.horizontal, 7)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
    }

    private var controls: some View {
        HStack(spacing: 6) {
            attachButton
            ClaudeModelMenu(session: session)
            ClaudeModeMenu(session: session)
            ClaudeEffortMenu(session: session)

            Spacer(minLength: 8)

            Button {
                session.newChat()
            } label: {
                Image(systemName: "square.and.pencil")
            }
            .buttonStyle(.borderless)
            .disabled(session.isEmpty)
            .help("Start a new conversation")
            .pointerCursor(!session.isEmpty)

            sendButton
        }
    }

    /// Straight to the file panel. There was a list of the repository's own
    /// files here first, which is one more thing to learn than a Mac user
    /// needs — the panel starts in the repository anyway.
    private var attachButton: some View {
        Button(action: browseForFiles) {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 22, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
        .help("Attach files to the prompt")
        .pointerCursor()
    }

    private func browseForFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.directoryURL = session.directory
        panel.prompt = "Attach"
        panel.message = "Attach files for Claude to read."
        guard panel.runModal() == .OK else { return }
        session.attach(panel.urls)
    }

    /// Stop and Send are both here while an answer is running: the CLI takes
    /// the next prompt whenever it is given one, so a follow-up does not have
    /// to wait for the turn to end.
    @ViewBuilder
    private var sendButton: some View {
        HStack(spacing: 6) {
            if session.isResponding {
                Button {
                    session.interrupt()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.red)
                .help("Stop what Claude is doing now")
                .pointerCursor()
            }

            Button {
                Task { await session.send() }
            } label: {
                Label("Send", systemImage: "paperplane.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(!session.canSend)
            .keyboardShortcut(.return, modifiers: .command)
            .help("Send the prompt (↩ or ⌘↩)")
            .pointerCursor(session.canSend)
        }
    }
}

/// One attached file. The ✕ is only there in the composer — in a message the
/// chip is a record of what was sent.
private struct AttachmentChip: View {
    let name: String
    var remove: (() -> Void)?

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "paperclip")
                .font(.system(size: 9))
            Text(name)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
            if let remove {
                Button(action: remove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .pointerCursor()
            }
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(.quaternary.opacity(0.35), in: Capsule())
        .help(name)
    }
}

// MARK: - Switchers

/// Which model answers. While it is on "Default" the button says which model
/// the CLI actually picked, once it has said so.
private struct ClaudeModelMenu: View {
    let session: ClaudeSession

    private var label: String {
        guard session.settings.model == .auto else { return session.settings.model.title }
        guard let resolved = session.resolvedModel else { return "Model" }
        return Self.shortName(resolved)
    }

    var body: some View {
        Menu {
            ForEach(ClaudeModel.allCases) { model in
                Button {
                    var settings = session.settings
                    settings.model = model
                    session.apply(settings)
                } label: {
                    if session.settings.model == model {
                        Label("\(model.title) — \(model.detail)", systemImage: "checkmark")
                    } else {
                        Text("\(model.title) — \(model.detail)")
                    }
                }
            }
        } label: {
            SwitcherLabel(symbol: "cpu", text: label)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Which model answers")
        .pointerCursor()
    }

    /// `claude-sonnet-5` reads as "Sonnet" on a button this size.
    private static func shortName(_ identifier: String) -> String {
        for family in ["opus", "sonnet", "haiku", "fable"] where identifier.contains(family) {
            return family.capitalized
        }
        return identifier
    }
}

/// What Claude may do without being asked.
private struct ClaudeModeMenu: View {
    let session: ClaudeSession

    /// Only the modes this Claude Code understands. An older one calls the
    /// hands-off mode something else and refuses the names it does not know.
    private var modes: [ClaudePermissionMode] {
        guard let cli = session.cli else { return ClaudePermissionMode.allCases }
        return ClaudePermissionMode.allCases.filter(cli.supports)
    }

    var body: some View {
        Menu {
            ForEach(modes) { mode in
                Button {
                    var settings = session.settings
                    settings.permissionMode = mode
                    session.apply(settings)
                } label: {
                    if session.settings.permissionMode == mode {
                        Label("\(mode.title) — \(mode.detail)", systemImage: "checkmark")
                    } else {
                        Text("\(mode.title) — \(mode.detail)")
                    }
                }
            }
        } label: {
            SwitcherLabel(
                symbol: session.settings.permissionMode.symbol,
                text: session.settings.permissionMode.title
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(session.settings.permissionMode.detail)
        .pointerCursor()
    }
}

/// How hard it thinks first. Away entirely on a Claude Code old enough not to
/// have the idea — an effort switcher that cannot be obeyed is worse than none.
private struct ClaudeEffortMenu: View {
    let session: ClaudeSession

    var body: some View {
        if session.cli?.supportsEffort != false {
            menu
        }
    }

    private var menu: some View {
        Menu {
            ForEach(ClaudeEffort.allCases) { effort in
                Button {
                    var settings = session.settings
                    settings.effort = effort
                    session.apply(settings)
                } label: {
                    if session.settings.effort == effort {
                        Label(effort.title, systemImage: "checkmark")
                    } else {
                        Text(effort.title)
                    }
                }
            }
        } label: {
            SwitcherLabel(
                symbol: "gauge.with.dots.needle.33percent",
                text: session.settings.effort == .standard ? "Effort" : session.settings.effort.title
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("How much thinking to do before answering")
        .pointerCursor()
    }
}

/// The shape all three switchers share, so the row reads as one control strip.
private struct SwitcherLabel: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 9))
            Text(text)
                .font(.caption)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 7))
                .foregroundStyle(.tertiary)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
    }
}
