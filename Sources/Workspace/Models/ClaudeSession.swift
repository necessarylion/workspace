import Foundation

/// One conversation with Claude Code about one repository.
///
/// It is the same `claude` the terminal runs, but driven rather than typed at:
/// `claude -p --input-format stream-json --output-format stream-json` keeps a
/// process up for the whole chat, takes a prompt as one line of JSON on stdin,
/// and answers with a line of JSON per event — text as it is written, tools as
/// they run, results as they come back. Which means the reply can be drawn as
/// a conversation instead of as terminal output, the way the editor extensions
/// do it.
///
/// The three switchers under the composer are process flags, not something that
/// can be changed mid-flight, so changing one marks the process for a restart.
/// Nothing is lost: the CLI hands out a session id, and the restart passes it
/// back with `--resume`, so the conversation carries on where it was.
@MainActor
@Observable
final class ClaudeSession: Identifiable {
    nonisolated let id = UUID()
    /// The repository the conversation is about — the process's working folder.
    nonisolated let directory: URL

    private(set) var messages: [ClaudeMessage] = []

    /// What is typed but not sent, and the files hung on it. Kept here so the
    /// half-written prompt survives leaving the chat and coming back.
    var draft = ""
    private(set) var attachments: [URL] = []

    private(set) var settings: ClaudeSettings

    /// Between sending a prompt and the reply ending.
    private(set) var isResponding = false
    /// While the process is booting, which takes a beat the first time.
    private(set) var isStarting = false
    /// While an old conversation is being read back off disk.
    private(set) var isLoadingTranscript = false
    private(set) var lastError: String?

    /// What the CLI says it is doing right now, when it says anything.
    private(set) var activity: String?

    /// The model the CLI settled on, which is the only way to name it while the
    /// model switcher is on "Default".
    private(set) var resolvedModel: String?

    /// The CLI's own id for this conversation, used to resume it after a
    /// restart. Nil until the first reply.
    private(set) var claudeSessionID: String?

    /// Which `claude` this Mac has and what it accepts, so the switchers only
    /// offer what will actually start. Nil until it has been looked up.
    private(set) var cli: ClaudeCLIInfo?

    /// What the composer completes. Both are ready before the first prompt —
    /// waiting for a `claude` process to start would mean an empty menu the
    /// first time you reach for one.
    private(set) var slashCommands: [ClaudeSlashCommand] = []
    private(set) var projectFiles: [String] = []

    @ObservationIgnored private var process: StreamingShellProcess?
    @ObservationIgnored private var reader: Task<Void, Never>?
    /// Which process the session is listening to. A restart starts the next one
    /// before the last one has finished dying, and its "I have exited" would
    /// otherwise land as a failure of the conversation that is already running.
    @ObservationIgnored private var processToken: UUID?
    /// Assistant messages by the id the API gave them, so the events that
    /// arrive about one can find it again.
    @ObservationIgnored private var messagesByID: [String: ClaudeMessage] = [:]
    @ObservationIgnored private var toolCalls: [String: ClaudeToolCall] = [:]
    /// Message id → the streaming block index → where that block sits in the
    /// message. The two are not the same once a block is inserted late.
    @ObservationIgnored private var blockSlots: [String: [Int: Int]] = [:]
    @ObservationIgnored private var streamingMessageID: String?
    @ObservationIgnored private var needsRestart = false
    @ObservationIgnored private var didInterrupt = false
    @ObservationIgnored private var requestCounter = 0

    init(directory: URL) {
        self.directory = directory
        self.settings = ClaudeSettings.restored()
        // Asked for straight away rather than at the first prompt: the
        // switchers under the composer are drawn from it, and finding the
        // binary means starting a shell.
        Task { cli = await ClaudeCLI.shared.info() }
    }

    var isEmpty: Bool { messages.isEmpty }

    /// Whether there is anything to send. Deliberately not "and it is not
    /// busy": the CLI takes a prompt while it is still answering the last one
    /// and picks it up when it gets there, so a follow-up never has to wait for
    /// a turn to finish.
    var canSend: Bool {
        !isStarting
            && !(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty)
    }

    // MARK: - Completions

    /// Reads the commands and the file list. Called when the chat appears, and
    /// again on demand — a command written while the chat was open should be
    /// offered without restarting anything.
    func loadCompletions() async {
        async let commands = ClaudeCompletions.commands(for: directory)
        async let files = ClaudeCompletions.files(in: directory)
        let carried = slashCommands.isEmpty
            ? ClaudeCompletions.rememberedBuiltIns()
            : slashCommands
        slashCommands = merge(await commands, into: carried)
        projectFiles = await files
    }

    /// Keeps whatever the CLI has told us about — its built-ins and the
    /// commands plugins add — alongside the ones read off disk, which are the
    /// only ones with a description worth showing.
    private func merge(
        _ fromDisk: [ClaudeSlashCommand],
        into existing: [ClaudeSlashCommand]
    ) -> [ClaudeSlashCommand] {
        let named = Set(fromDisk.map(\.name))
        return fromDisk + existing.filter { $0.source == .builtIn && !named.contains($0.name) }
    }

    // MARK: - Composing

    func attach(_ urls: [URL]) {
        for url in urls where !attachments.contains(url) {
            attachments.append(url)
        }
    }

    func removeAttachment(_ url: URL) {
        attachments.removeAll { $0 == url }
    }

    /// A file's path as it should read in the prompt: relative to the
    /// repository when it is inside it, so `@Sources/App.swift` is what Claude
    /// sees, and absolute when it is not.
    func displayPath(of url: URL) -> String {
        let root = directory.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(root + "/") else { return path }
        return String(path.dropFirst(root.count + 1))
    }

    // MARK: - Sending

    func send() async {
        guard canSend else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let files = attachments
        draft = ""
        attachments = []
        lastError = nil
        didInterrupt = false

        let message = ClaudeMessage(id: "prompt-\(UUID().uuidString)", role: .user)
        message.blocks = [.text(ClaudeTextBlock(id: message.id + "-text", text: text))]
        message.attachments = files
        messages.append(message)

        isResponding = true
        activity = nil
        await deliver(prompt(text: text, attachments: files))
    }

    /// The `@mentions` go in front of the prompt rather than at the end of it,
    /// which is where they would land if the user typed them, and is what makes
    /// Claude read those files before answering.
    private func prompt(text: String, attachments: [URL]) -> String {
        guard !attachments.isEmpty else { return text }
        let mentions = attachments.map { "@" + displayPath(of: $0) }.joined(separator: " ")
        return text.isEmpty ? mentions : mentions + "\n\n" + text
    }

    private func deliver(_ prompt: String) async {
        if needsRestart { stopProcess() }
        if process == nil || process?.isRunning != true {
            await startProcess()
        }
        guard let process, process.isRunning else {
            isResponding = false
            return
        }
        send(json: [
            "type": "user",
            "message": ["role": "user", "content": [["type": "text", "text": prompt]]],
        ])
    }

    /// Asks the CLI to drop what it is doing. The conversation survives — the
    /// same process answers the next prompt.
    func interrupt() {
        guard isResponding, let process, process.isRunning else { return }
        didInterrupt = true
        requestCounter += 1
        send(json: [
            "type": "control_request",
            "request_id": "stop-\(requestCounter)",
            "request": ["subtype": "interrupt"],
        ])
    }

    private func send(json object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let line = String(data: data, encoding: .utf8) else { return }
        process?.send(line)
    }

    // MARK: - Settings

    /// Takes the switchers' new state. The flags belong to the process, so this
    /// only lines up a restart; the next prompt pays for it, and resumes the
    /// conversation rather than starting a new one.
    func apply(_ new: ClaudeSettings) {
        guard new != settings else { return }
        settings = new
        settings.persist()
        needsRestart = true
        // Idle: get it over with now, so the next prompt is not slowed down by
        // a process still shutting down.
        if !isResponding { stopProcess() }
    }

    // MARK: - Lifetime

    /// Throws the conversation away and starts over, leaving the switchers as
    /// they are.
    func newChat() {
        stopProcess()
        messages = []
        messagesByID = [:]
        toolCalls = [:]
        blockSlots = [:]
        streamingMessageID = nil
        claudeSessionID = nil
        lastError = nil
        activity = nil
        isResponding = false
    }

    /// Ends the process for good — the repository is being removed, or the app
    /// is quitting. The transcript stays on screen.
    func shutDown() {
        stopProcess()
    }

    /// Picks up a conversation from the sessions list — one this window had
    /// before, or one that was had in a shell; the CLI writes both to the same
    /// place.
    ///
    /// The transcript is read off disk so there is something to come back *to*,
    /// and the id is kept so the next prompt goes out with `--resume`. No
    /// process is started here: opening an old conversation to read it should
    /// not cost a Claude Code launch.
    func resume(_ past: ClaudePastSession) async {
        guard past.id != claudeSessionID || messages.isEmpty else { return }
        newChat()
        claudeSessionID = past.id
        isLoadingTranscript = true
        defer { isLoadingTranscript = false }

        for entry in await ClaudeSessionsIndex.transcript(of: past.file) {
            replay(entry)
        }
        for message in messages { message.isStreaming = false }
        // Nothing arrived over a live stream, so no tool is still running: a
        // call left without a result is one whose result was cut off by the
        // window this transcript was read through.
        for call in toolCalls.values where call.result == nil {
            call.result = ""
        }
    }

    /// One line of a transcript file. The entries are the same shape as the
    /// events a live session sends, so they go through the same two readers.
    private func replay(_ entry: JSONValue) {
        switch entry["type"]?.stringValue {
        case "assistant": handleAssistant(entry)
        case "user": handleUser(entry, includingPrompts: true)
        default: break
        }
    }

    private func startProcess() async {
        isStarting = true
        defer { isStarting = false }
        needsRestart = false

        let info = await ClaudeCLI.shared.info()
        cli = info
        guard let executable = info.executable else {
            lastError = "Claude Code is not installed. Install it, or check Settings ▸ Requirements."
            isResponding = false
            return
        }

        let process = StreamingShellProcess()
        let token = UUID()
        self.process = process
        processToken = token
        await process.start(
            executable,
            arguments: processArguments(info),
            in: directory
        ) { [weak self] status in
            Task { @MainActor in self?.processEnded(status: status, token: token) }
        }
        reader = Task { [weak self] in
            for await line in process.lines {
                guard let self else { return }
                self.handle(line)
            }
        }
    }

    private func processArguments(_ info: ClaudeCLIInfo) -> [String] {
        var arguments = [
            "-p",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            // Without this the reply only lands once it is finished; with it,
            // the text arrives as it is written.
            "--include-partial-messages",
            // stream-json output is refused without it.
            "--verbose",
            // Under the name this particular CLI knows the mode by.
            "--permission-mode", info.flagValue(for: settings.permissionMode),
        ]
        if let model = settings.model.flagValue {
            arguments += ["--model", model]
        }
        // An older Claude Code has no notion of effort, and refuses to start
        // rather than ignoring the flag.
        if info.supportsEffort, let effort = settings.effort.flagValue {
            arguments += ["--effort", effort]
        }
        if let session = claudeSessionID {
            arguments += ["--resume", session]
        }
        return arguments
    }

    private func stopProcess() {
        reader?.cancel()
        reader = nil
        process?.terminate()
        process = nil
        processToken = nil
        streamingMessageID = nil
        for message in messages { message.isStreaming = false }
    }

    private func processEnded(status: Int32, token: UUID) {
        // A process this session has already let go of. Its death is the
        // restart working, not something to report.
        guard token == processToken else { return }
        processToken = nil

        for message in messages { message.isStreaming = false }
        streamingMessageID = nil
        activity = nil
        // A process that ends between prompts is the expected way a restart
        // begins; only one that dies mid-answer has something to report.
        if isResponding {
            let stderr = process?.errorOutput ?? ""
            lastError = stderr.isEmpty
                ? "Claude Code stopped unexpectedly (exit \(status))."
                : stderr
            isResponding = false
        }
        process = nil
    }

    // MARK: - Reading the stream

    private func handle(_ line: String) {
        guard let event = JSONValue.parse(line),
              let type = event["type"]?.stringValue else { return }
        // Work a subagent does is its own conversation; only what the main one
        // says belongs in this transcript.
        guard event["parent_tool_use_id"]?.stringValue == nil else { return }

        switch type {
        case "system": handleSystem(event)
        case "stream_event": handleStreamEvent(event)
        case "assistant": handleAssistant(event)
        case "user": handleUser(event)
        case "result": handleResult(event)
        default: break
        }
    }

    private func handleSystem(_ event: JSONValue) {
        switch event["subtype"]?.stringValue {
        case "init":
            // Sent at the top of every turn, not just the first one.
            claudeSessionID = event["session_id"]?.stringValue ?? claudeSessionID
            resolvedModel = event["model"]?.stringValue ?? resolvedModel
            // The only place the built-in commands, and whatever plugins and
            // MCP servers add, can be learned from.
            if let reported = event["slash_commands"]?.arrayValue {
                setBuiltInCommands(reported.compactMap(\.stringValue))
            }
        case "status":
            activity = event["status"]?.stringValue
        default:
            break
        }
    }

    private func handleStreamEvent(_ event: JSONValue) {
        guard let inner = event["event"], let kind = inner["type"]?.stringValue else { return }

        switch kind {
        case "message_start":
            guard let id = inner["message"]?["id"]?.stringValue else { return }
            _ = assistantMessage(id)
        case "content_block_start":
            guard let id = streamingMessageID,
                  let index = inner["index"]?.intValue,
                  let block = inner["content_block"] else { return }
            startBlock(block, at: index, in: id)
        case "content_block_delta":
            guard let id = streamingMessageID,
                  let index = inner["index"]?.intValue,
                  let delta = inner["delta"] else { return }
            appendDelta(delta, at: index, in: id)
        case "message_stop":
            if let id = streamingMessageID { messagesByID[id]?.isStreaming = false }
        default:
            break
        }
    }

    private func startBlock(_ block: JSONValue, at index: Int, in messageID: String) {
        guard let message = messagesByID[messageID] else { return }
        let slotID = "\(messageID)-\(index)"

        let new: ClaudeBlock
        switch block["type"]?.stringValue {
        case "thinking", "redacted_thinking":
            new = .thinking(ClaudeTextBlock(id: slotID))
        case "tool_use":
            let call = ClaudeToolCall(
                id: block["id"]?.stringValue ?? slotID,
                name: block["name"]?.stringValue ?? "Tool"
            )
            toolCalls[call.id] = call
            new = .tool(call)
        default:
            new = .text(ClaudeTextBlock(id: slotID, text: block["text"]?.stringValue ?? ""))
        }

        message.blocks.append(new)
        blockSlots[messageID, default: [:]][index] = message.blocks.count - 1
    }

    private func appendDelta(_ delta: JSONValue, at index: Int, in messageID: String) {
        guard let message = messagesByID[messageID],
              let slot = blockSlots[messageID]?[index],
              message.blocks.indices.contains(slot) else { return }

        switch (delta["type"]?.stringValue, message.blocks[slot]) {
        case ("text_delta", .text(let block)):
            block.text += delta["text"]?.stringValue ?? ""
        case ("thinking_delta", .thinking(let block)):
            block.text += delta["thinking"]?.stringValue ?? ""
        case ("input_json_delta", .tool(let call)):
            call.partialInput += delta["partial_json"]?.stringValue ?? ""
        default:
            break
        }
    }

    /// The confirmed form of one block. These arrive one at a time, in order,
    /// after the deltas that built the same block — a tool call's arguments,
    /// for one, are only whole here.
    private func handleAssistant(_ event: JSONValue) {
        guard let payload = event["message"],
              let id = payload["id"]?.stringValue else { return }
        let message = assistantMessage(id)
        for block in payload["content"]?.arrayValue ?? [] {
            commit(block, to: message)
        }
    }

    private func commit(_ block: JSONValue, to message: ClaudeMessage) {
        let slot = message.committedCount
        message.committedCount += 1
        let existing = message.blocks.indices.contains(slot) ? message.blocks[slot] : nil
        let slotID = "\(message.id)-c\(slot)"

        func insert(_ new: ClaudeBlock) {
            message.blocks.insert(new, at: min(slot, message.blocks.count))
        }

        switch block["type"]?.stringValue {
        case "thinking", "redacted_thinking":
            // The confirmed copy carries the signature, not the words — those
            // only ever arrive as deltas — so what streamed in stays put.
            let text = block["thinking"]?.stringValue ?? ""
            if case .thinking(let streamed)? = existing {
                if !text.isEmpty { streamed.text = text }
            } else {
                insert(.thinking(ClaudeTextBlock(id: slotID, text: text)))
            }
        case "tool_use":
            let id = block["id"]?.stringValue ?? slotID
            let call: ClaudeToolCall
            if case .tool(let streamed)? = existing, streamed.id == id {
                call = streamed
            } else if let known = toolCalls[id] {
                call = known
                insert(.tool(call))
            } else {
                call = ClaudeToolCall(id: id, name: block["name"]?.stringValue ?? "Tool")
                insert(.tool(call))
            }
            if let name = block["name"]?.stringValue { call.name = name }
            if let input = block["input"] { call.input = input }
            toolCalls[id] = call
        default:
            let text = block["text"]?.stringValue ?? ""
            if case .text(let streamed)? = existing {
                if !text.isEmpty { streamed.text = text }
            } else if !text.isEmpty {
                insert(.text(ClaudeTextBlock(id: slotID, text: text)))
            }
        }
    }

    /// Everything that arrives as "user": tool results, and text.
    ///
    /// Which side that text came from depends on where the event came from.
    /// Live, the prompts are ours and anything coming *back* is the CLI writing
    /// about the conversation — that it was interrupted, say. Replayed from a
    /// transcript, the same entries are the prompts themselves, and they are
    /// what the conversation is made of.
    private func handleUser(_ event: JSONValue, includingPrompts: Bool = false) {
        for block in event["message"]?["content"]?.arrayValue ?? [] {
            switch block["type"]?.stringValue {
            case "tool_result":
                guard let id = block["tool_use_id"]?.stringValue,
                      let call = toolCalls[id] else { continue }
                call.result = Self.resultText(block["content"])
                call.isError = block["is_error"]?.boolValue ?? false
            case "text":
                let text = (block["text"]?.stringValue ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                if includingPrompts, Self.isPrompt(text) {
                    addPrompt(text)
                } else {
                    addNote(text)
                }
            default:
                break
            }
        }
    }

    /// Whether replayed text is something the user actually typed, rather than
    /// the CLI's own bookkeeping going through the same channel: a slash
    /// command's expansion, the caveat it prepends to a resumed session, the
    /// line it writes when a turn is cut short.
    private static func isPrompt(_ text: String) -> Bool {
        !text.hasPrefix("<")
            && !text.hasPrefix("Caveat:")
            && !text.hasPrefix("[Request interrupted")
    }

    private func addPrompt(_ text: String) {
        let message = ClaudeMessage(id: "past-\(messages.count)", role: .user)
        message.blocks = [.text(ClaudeTextBlock(id: "past-\(messages.count)-text", text: text))]
        messages.append(message)
    }

    /// A tool's output is a string for most tools and a list of text parts for
    /// the ones that can return more than one thing.
    private static func resultText(_ content: JSONValue?) -> String {
        guard let content else { return "" }
        if let text = content.stringValue { return text }
        guard let parts = content.arrayValue else { return content.displayText }
        return parts
            .compactMap { $0["text"]?.stringValue ?? ($0["type"]?.stringValue == "image" ? "[image]" : nil) }
            .joined(separator: "\n")
    }

    private func handleResult(_ event: JSONValue) {
        isResponding = false
        activity = nil
        streamingMessageID = nil
        for message in messages { message.isStreaming = false }

        guard event["is_error"]?.boolValue == true else { return }
        // Stopping mid-tool is an error as far as the CLI is concerned, but it
        // is exactly what the stop button asked for.
        if didInterrupt {
            didInterrupt = false
            return
        }
        lastError = event["result"]?.stringValue ?? "Claude Code ended the turn with an error."
    }

    /// What the CLI says it has. This *replaces* the built-in half of the menu
    /// rather than adding to it: the report is the whole truth about this
    /// install, so a command we offered by default that this version does not
    /// have should stop being offered. The repository's and your own commands
    /// are untouched — they are read from disk and the CLI has nothing to say
    /// about them that we do not already know.
    ///
    /// Kept for next time, too: this is the only moment they can be learned,
    /// and the menu should not be half empty until the first prompt of every
    /// session.
    private func setBuiltInCommands(_ names: [String]) {
        ClaudeCompletions.remember(builtIns: names)
        let fromFiles = slashCommands.filter { $0.source != .builtIn }
        let taken = Set(fromFiles.map(\.name))
        slashCommands = (fromFiles + ClaudeCompletions.builtIns(named: names).filter { !taken.contains($0.name) })
            .sorted { $0.name < $1.name }
    }

    private func addNote(_ text: String) {
        let note = ClaudeMessage(id: "note-\(UUID().uuidString)", role: .note)
        note.blocks = [.text(ClaudeTextBlock(id: note.id + "-text", text: text))]
        messages.append(note)
    }

    private func assistantMessage(_ id: String) -> ClaudeMessage {
        streamingMessageID = id
        // A queued prompt starts being answered *after* the turn before it has
        // already reported itself finished — stopping one turn while another
        // is waiting is exactly that shape — so an answer arriving is what says
        // the session is busy again.
        if process?.isRunning == true { isResponding = true }
        if let existing = messagesByID[id] { return existing }
        let message = ClaudeMessage(id: id, role: .assistant)
        message.isStreaming = true
        messagesByID[id] = message
        messages.append(message)
        return message
    }
}
