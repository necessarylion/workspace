import AppKit
import SwiftUI

/// How wide a conversation is allowed to get. A line of text past this is
/// tiring to read on a wide window, and the composer is held to the same
/// figure so the prompt lines up with the messages it joins.
enum ClaudeChatMetrics {
    static let columnWidth: CGFloat = 760

    /// The empty stretch kept below the newest message.
    static let tailSpace: CGFloat = 200

    /// How a message, a tool row or the working line arrives: a short fade with
    /// a few points of travel under it, so a reply settles onto the transcript
    /// instead of snapping into place a block at a time.
    static var appear: AnyTransition { .opacity.combined(with: .offset(y: 6)) }
    static let appearing: Animation = .easeOut(duration: 0.18)
}

/// The Claude Code chat, in the centre pane.
///
/// The transcript is above and the composer below, the way the editor
/// extensions lay it out: a box to type in, and under it the switchers that
/// decide who answers and what they are allowed to do.
struct ClaudeChatView: View {
    @Bindable var session: ClaudeSession
    let project: Project?
    /// Whether this is the conversation on screen. Every open chat stays in the
    /// view tree and the ones not being read are merely made transparent, so
    /// this is the only signal that one has been come back to.
    var isOnScreen = true

    @Environment(WorkspaceStore.self) private var store

    /// Where the scroll view parks itself as the reply grows.
    private let bottomAnchor = "claude-bottom"

    /// Whether the transcript is still following the reply down. Kept for the
    /// life of the view, and read only when something new arrives.
    @State private var pin = ChatScrollPin()

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
                            answer: answer,
                            didResize: session.contentResized
                        )
                        .transition(ClaudeChatMetrics.appear)
                    }
                    // Kept up for the whole turn, including while a paragraph is
                    // being written. A turn spends most of itself between
                    // paragraphs — thinking, or inside a tool — and a
                    // transcript that ends on a finished row with nothing under
                    // it reads as finished, when it is only busy.
                    if session.isStarting {
                        ClaudeWorkingLine(fixed: "Starting Claude Code…")
                            .transition(ClaudeChatMetrics.appear)
                    } else if session.isResponding {
                        ClaudeWorkingLine(session: session)
                            .transition(ClaudeChatMetrics.appear)
                    }
                    if let error = session.lastError {
                        errorNotice(error)
                            .transition(ClaudeChatMetrics.appear)
                    }
                    // Room under the last message, so a reply finishes in the
                    // middle of the pane rather than jammed against the box you
                    // type in. The transcript parks on the bottom of *this*, so
                    // the space is what you are left looking at.
                    Color.clear
                        .frame(height: ClaudeChatMetrics.tailSpace)
                        .id(bottomAnchor)
                }
                // Animated on what has arrived, never on what is being written:
                // a reply's own text grows a character at a time and animating
                // that would fight the typing rather than smooth it.
                .animation(ClaudeChatMetrics.appearing, value: session.messages.count)
                .animation(ClaudeChatMetrics.appearing, value: session.isResponding)
                .animation(ClaudeChatMetrics.appearing, value: session.isStarting)
                .frame(maxWidth: ClaudeChatMetrics.columnWidth, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity, alignment: .top)
                // Behind the whole transcript rather than in the overlay below:
                // it has to be *inside* the scroll view to find it, and a
                // background of the content is the one thing in there that is
                // never scrolled out of existence.
                .background(ChatScrollPinReporter(pin: pin))
            }
            // Following the reply down is done by a view of its own rather than
            // here. Watching the transcript grow from this level would mean this
            // body — every bubble in the conversation — is rebuilt on every
            // token; the follower draws nothing, so rebuilding it costs nothing.
            .overlay {
                ChatScrollFollower(
                    session: session,
                    proxy: proxy,
                    anchor: bottomAnchor,
                    pin: pin,
                    isOnScreen: isOnScreen
                )
            }
            // The way back down, shown only while there is a way back down to
            // take. A view of its own, because it is the one thing on this page
            // that reads the pin from a body — put in the transcript's own, it
            // would rebuild every bubble each time the pointer moved the wheel.
            .overlay(alignment: .bottomTrailing) {
                ChatScrollToBottomButton(pin: pin) {
                    withAnimation(.easeOut(duration: 0.22)) {
                        proxy.scrollTo(bottomAnchor, anchor: .bottom)
                    }
                }
            }
        }
        .textSelection(.enabled)
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
}

// MARK: - Following the reply

/// Whether the transcript is parked at its bottom, and so whether it should
/// follow the next thing that arrives.
///
/// Observable, but only just: the button that offers the way back down is the
/// single view that reads this from a body, and so the single view rebuilt when
/// it changes. The follower reads it at the moment it is deciding, which is not
/// a read SwiftUI tracks — which matters, because that read happens on every
/// token of every reply.
@MainActor
@Observable
final class ChatScrollPin {
    /// Starts true: a conversation opens on its newest message.
    var isAtBottom = true
}

/// The way back to the newest message, floating over the transcript's bottom
/// corner while the reader is anywhere else.
///
/// It is the whole indication that the transcript has stopped following: with
/// the reply still landing out of sight, a reader scrolled up has nothing else
/// to say the end has moved on.
private struct ChatScrollToBottomButton: View {
    let pin: ChatScrollPin
    let scrollToBottom: () -> Void

    @State private var isHovering = false

    var body: some View {
        Group {
            if !pin.isAtBottom {
                Button {
                    scrollToBottom()
                    // Said here rather than waited for: the scroll reports back
                    // as it travels, and the button should go the moment it is
                    // pressed, not when the transcript arrives.
                    pin.isAtBottom = true
                } label: {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(isHovering ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                        .frame(width: 32, height: 32)
                        .background(.regularMaterial, in: Circle())
                        .overlay {
                            Circle().strokeBorder(.quaternary)
                        }
                        .shadow(color: .black.opacity(0.18), radius: 5, y: 2)
                }
                .buttonStyle(.plain)
                .onHover { isHovering = $0 }
                .pointerCursor()
                .help("Jump to the newest message")
                .padding(.trailing, 20)
                .padding(.bottom, 16)
                .transition(.scale(scale: 0.8).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.16), value: pin.isAtBottom)
    }
}

/// Keeps the transcript parked at the bottom while a reply is being written —
/// unless the reader has scrolled up, which stops it until they come back.
///
/// It draws nothing. The point is *where* it sits in the view tree: the counter
/// it watches ticks on every token, and whichever view reads it is rebuilt that
/// often. Here that is a `Color.clear`. Read from the transcript's own body
/// instead — which is what measuring the last message amounted to — and every
/// bubble, every tool row and every code block in the conversation was rebuilt
/// per token, which is what made a long answer crawl.
private struct ChatScrollFollower: View {
    let session: ClaudeSession
    let proxy: ScrollViewProxy
    let anchor: String
    let pin: ChatScrollPin
    let isOnScreen: Bool

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .onChange(of: session.messages.count) { follow(isNewTurn: true) }
            .onChange(of: session.isResponding) { follow() }
            .onChange(of: session.growth) { follow() }
            // A conversation opens on its newest message, every time it is
            // opened. The chat is never torn out of the view tree, so coming
            // back to it otherwise means coming back to the exact scroll
            // position it was left at — which, after reading back through an
            // old answer, is nowhere near what has happened since.
            //
            // Twice, a beat apart: the first goes in while the pane may still
            // be laying out — a transcript replayed off disk has barely any of
            // itself built on the frame it is shown in — and the second lands
            // once there is something to scroll to. The wait is too short to
            // be seen, and is dropped if the reader has already scrolled.
            .task(id: isOnScreen) {
                guard isOnScreen else { return }
                pin.isAtBottom = true
                proxy.scrollTo(anchor, anchor: .bottom)
                try? await Task.sleep(for: .milliseconds(60))
                guard pin.isAtBottom else { return }
                proxy.scrollTo(anchor, anchor: .bottom)
            }
    }

    /// Follows only while the reader is at the bottom. Reading back through a
    /// long answer meant being thrown to the end of it every time another
    /// paragraph landed, which is the one thing that makes a transcript
    /// unreadable while it is being written.
    ///
    /// The exception is a prompt you just sent: that is a turn *you* started,
    /// and it re-parks the transcript wherever you had left it.
    private func follow(isNewTurn: Bool = false) {
        if isNewTurn, session.messages.last?.role == .user {
            pin.isAtBottom = true
        }
        guard pin.isAtBottom else { return }
        proxy.scrollTo(anchor, anchor: .bottom)
    }
}

/// Watches the transcript's scroll position and keeps ``ChatScrollPin`` up to
/// date. Draws nothing and takes no clicks.
///
/// This is done in AppKit because the question — how far the content's bottom
/// is from the bottom of the pane — is one `NSScrollView` answers exactly, and
/// it answers it without SwiftUI having to redraw anything to ask. It listens
/// for the clip view moving, which is what a scroll is; the content *growing*
/// deliberately raises nothing, so a reply arriving never unpins the view by
/// itself.
private struct ChatScrollPinReporter: NSViewRepresentable {
    let pin: ChatScrollPin

    func makeNSView(context: Context) -> NSView {
        let view = Reporter()
        view.pin = pin
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? Reporter)?.pin = pin
    }

    final class Reporter: NSView {
        /// How close to the end still counts as the end. Bigger than it looks
        /// it needs to be: parking on the tail anchor still leaves the
        /// transcript's own bottom padding below it, so "at the bottom" is
        /// never zero to the pixel. Well under what scrolling back to read
        /// anything costs — the empty stretch under the last message is 200.
        private static let slack: CGFloat = 48

        var pin: ChatScrollPin?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observe()
        }

        /// Target/action rather than a block: the centre drops a dead observer
        /// registered this way by itself, which spares this view a `deinit` it
        /// could not write anyway — a view's is not on the main actor.
        private func observe() {
            NotificationCenter.default.removeObserver(
                self,
                name: NSView.boundsDidChangeNotification,
                object: nil
            )
            guard window != nil, let clip = enclosingScrollView?.contentView else { return }
            clip.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(scrolled),
                name: NSView.boundsDidChangeNotification,
                object: clip
            )
            // Whatever the position is on the way in — a conversation replayed
            // from disk opens somewhere already.
            update()
        }

        @objc private func scrolled() {
            update()
        }

        private func update() {
            guard let pin,
                  let scrollView = enclosingScrollView,
                  let document = scrollView.documentView
            else { return }
            let visible = scrollView.contentView.bounds
            // A transcript shorter than the pane is at its bottom by default.
            let distance = document.frame.height - visible.maxY
            let isAtBottom = distance <= Self.slack
            // Only on a change. A scroll raises this many times a second, and
            // the observation behind the pin fires on every write, not on every
            // difference — so writing the same answer over and over would
            // rebuild the button all the way down the page.
            guard pin.isAtBottom != isAtBottom else { return }
            pin.isAtBottom = isAtBottom
        }
    }
}

// MARK: - Empty state

private struct ClaudeChatWelcome: View {
    let session: ClaudeSession
    let project: Project?

    /// The jobs a repository is opened for, not a tour of it: what is offered
    /// here is what gets asked on most days, in the order a change goes out —
    /// look at it, commit it, put it up for review.
    private var suggestions: [String] {
        [
            "Review the changes on this branch",
            "Commit all my changes and push",
            "Create a pull request for this branch",
            "Explain the changes I have not committed yet",
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
    /// Passed down to the tool rows, which find out how tall they are a beat
    /// after they appear — see ``ClaudeToolRow/didResize``.
    var didResize: () -> Void = {}

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

    /// A prompt wears the accent colour — a tinted box behind a thin border of
    /// the same blue — so a glance down the transcript separates what you asked
    /// from what came back without having to read either.
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
        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.45), lineWidth: 1)
        }
    }

    /// No mark down the side of the reply: the whole pane is Claude, and one
    /// per message is a column of the same icon repeating past what it says.
    /// The box around a prompt is what tells the two sides apart.
    private var assistantMessage: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(message.blocks) { block in
                Group {
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
                        ClaudeToolRow(call: call, openFile: openFile, didResize: didResize)
                    }
                }
                .transition(ClaudeChatMetrics.appear)
            }
            if !quickReplies.isEmpty {
                ClaudeQuickReplyRow(replies: quickReplies, answer: answer)
                    .padding(.top, 2)
                    .transition(ClaudeChatMetrics.appear)
            }
        }
        // A tool row landing in the middle of a reply fades in like the reply
        // did. Keyed on how many blocks there are, so the text arriving inside
        // one of them is not an animation.
        .animation(ClaudeChatMetrics.appearing, value: message.blocks.count)
        .animation(ClaudeChatMetrics.appearing, value: quickReplies.isEmpty)
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
        .textSelection(.disabled)
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
                // Selectable text swallows the click meant for the button
                // under it — see `ClaudeToolRow.header`.
                .textSelection(.disabled)
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
        // The same column the transcript is read in, so the box you type in
        // starts and ends where the messages above it do. The bar behind it
        // still runs the whole width of the pane — it is the floor of the
        // window, not part of the column.
        .frame(maxWidth: ClaudeChatMetrics.columnWidth, alignment: .leading)
        .padding(12)
        .frame(maxWidth: .infinity)
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

    /// Where the attach panel last had something picked from it, kept across
    /// launches. Attachments come from the same handful of folders — screenshots
    /// out of Downloads, a log off the Desktop — and none of them is the
    /// repository, so opening on the repository every time means walking back
    /// to the same folder on every attachment.
    @AppStorage("claude.attachDirectory") private var lastAttachDirectory = ""

    private func browseForFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        // The remembered folder, but only while it is still there — a panel
        // pointed at a folder that has been moved or thrown away opens
        // wherever AppKit decides, which is worse than the repository.
        panel.directoryURL = Self.existingDirectory(lastAttachDirectory) ?? session.directory
        panel.prompt = "Attach"
        panel.message = "Attach files for Claude to read."
        guard panel.runModal() == .OK else { return }
        // The folder the files came from rather than the panel's own — those
        // differ the moment the picking is done from a search or a favourite.
        if let folder = panel.urls.first?.deletingLastPathComponent() {
            lastAttachDirectory = folder.path
        }
        session.attach(panel.urls)
    }

    private static func existingDirectory(_ path: String) -> URL? {
        guard !path.isEmpty else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { return nil }
        return URL(fileURLWithPath: path)
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
                }
                .buttonStyle(.borderedProminent)
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
