import Foundation

/// What one turn of the conversation is made of.
///
/// A message is one API message: the user's prompt, or one assistant reply. An
/// assistant reply is a list of blocks — text it wrote, thinking it did, tools
/// it ran — in the order they happened, which is how the transcript reads.
@MainActor
@Observable
final class ClaudeMessage: Identifiable {
    enum Role {
        case user, assistant
        /// Notes the CLI makes about the conversation itself, like an
        /// interruption. Not something either side said.
        case note
    }

    nonisolated let id: String
    nonisolated let role: Role

    var blocks: [ClaudeBlock] = []

    /// Files the user hung on their prompt, so the bubble can list them under
    /// the text rather than leaving the `@path` mentions to speak for it.
    var attachments: [URL] = []

    /// How many blocks the CLI has confirmed. Blocks stream in as deltas first
    /// and are confirmed one at a time afterwards, so this is where the next
    /// confirmation lands. See ``ClaudeSession/commit(_:to:)``.
    var committedCount = 0

    /// Set while this reply is still being written.
    var isStreaming = false

    init(id: String, role: Role) {
        self.id = id
        self.role = role
    }

    /// The whole reply as plain text, for the copy button.
    var plainText: String {
        blocks.compactMap {
            if case .text(let block) = $0 { return block.text }
            return nil
        }
        .joined(separator: "\n\n")
    }
}

/// One part of a message.
enum ClaudeBlock: Identifiable {
    case text(ClaudeTextBlock)
    case thinking(ClaudeTextBlock)
    case tool(ClaudeToolCall)

    nonisolated var id: String {
        switch self {
        case .text(let block), .thinking(let block): block.id
        case .tool(let call): call.id
        }
    }
}

/// Text the model wrote, or thought. A class rather than a `String` so the
/// deltas that arrive token by token can be appended in place, and only the one
/// paragraph on screen redraws.
@MainActor
@Observable
final class ClaudeTextBlock: Identifiable {
    nonisolated let id: String
    var text: String

    init(id: String, text: String = "") {
        self.id = id
        self.text = text
    }
}

/// One tool the model ran, and what came back.
@MainActor
@Observable
final class ClaudeToolCall: Identifiable {
    nonisolated let id: String
    var name: String
    var input: JSONValue = .object([:])
    /// Filled in from `input_json_delta` while the call is still being written;
    /// the confirmed message replaces `input` with the parsed whole.
    var partialInput = ""
    var result: String?
    var isError = false
    /// Whether the row is unfolded to show the full input and result.
    var isExpanded = false

    var isRunning: Bool { result == nil }

    init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    /// The glyph for this tool, so a long reply can be skimmed by shape.
    var symbol: String {
        switch name {
        case "Read", "NotebookEdit": "doc.text"
        case "Edit", "MultiEdit": "pencil"
        case "Write": "square.and.pencil"
        case "Bash", "BashOutput", "KillShell": "terminal"
        case "Grep": "magnifyingglass"
        case "Glob", "LS": "folder"
        case "WebFetch", "WebSearch": "globe"
        case "Task", "Agent": "sparkles"
        case "TodoWrite": "checklist"
        case "Skill": "wand.and.stars"
        default: name.hasPrefix("mcp__") ? "puzzlepiece.extension" : "wrench.and.screwdriver"
        }
    }

    /// The one thing worth seeing without unfolding the row: the command, the
    /// file, the pattern. Falls back to nothing rather than to a wall of JSON.
    var summary: String {
        for key in ["command", "file_path", "path", "pattern", "url", "prompt", "description", "query"] {
            if let value = input[key]?.stringValue, !value.isEmpty {
                return value
            }
        }
        return ""
    }
}

// MARK: - Settings

/// Which model answers. `auto` leaves the flag off, so the CLI uses whatever
/// the user configured for themselves.
enum ClaudeModel: String, CaseIterable, Identifiable {
    case auto, opus, sonnet, haiku, fable

    var id: String { rawValue }

    /// What the CLI's `--model` should be, or nil to leave it alone.
    var flagValue: String? { self == .auto ? nil : rawValue }

    var title: String {
        switch self {
        case .auto: "Default"
        case .opus: "Opus"
        case .sonnet: "Sonnet"
        case .haiku: "Haiku"
        case .fable: "Fable"
        }
    }

    var detail: String {
        switch self {
        case .auto: "Whatever Claude Code is set to"
        case .opus: "The most capable"
        case .sonnet: "Balanced"
        case .haiku: "The fastest"
        case .fable: "Lightweight"
        }
    }
}

/// How hard the model thinks before answering.
enum ClaudeEffort: String, CaseIterable, Identifiable {
    case standard, low, medium, high, xhigh, max

    var id: String { rawValue }

    var flagValue: String? { self == .standard ? nil : rawValue }

    var title: String {
        switch self {
        case .standard: "Default"
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        case .xhigh: "Extra High"
        case .max: "Max"
        }
    }
}

/// What Claude is allowed to do without being asked.
///
/// The CLI also has a mode that stops and asks before every tool — `manual` on
/// a recent one, `default` on an older one. It is left out on purpose: asking
/// needs a prompt to answer on, and in this window there is nowhere to answer,
/// so every request would simply be refused.
enum ClaudePermissionMode: String, CaseIterable, Identifiable {
    case auto
    case plan
    case acceptEdits
    case bypassPermissions

    var id: String { rawValue }

    /// The names this mode goes by, newest first. Claude Code renamed the
    /// hands-off mode from `default` to `auto`, and which one is understood
    /// depends on the version installed — see ``ClaudeCLIInfo/flagValue(for:)``.
    var flagCandidates: [String] {
        switch self {
        case .auto: ["auto", "default"]
        case .plan: ["plan"]
        case .acceptEdits: ["acceptEdits"]
        case .bypassPermissions: ["bypassPermissions"]
        }
    }

    var title: String {
        switch self {
        case .auto: "Auto"
        case .plan: "Plan"
        case .acceptEdits: "Accept Edits"
        case .bypassPermissions: "Full Access"
        }
    }

    var symbol: String {
        switch self {
        case .auto: "wand.and.sparkles"
        case .plan: "list.bullet.clipboard"
        case .acceptEdits: "pencil.circle"
        case .bypassPermissions: "lock.open"
        }
    }

    var detail: String {
        switch self {
        case .auto: "Claude decides what is safe to run on its own"
        case .plan: "Reads and plans, changes nothing"
        case .acceptEdits: "File edits go through without asking"
        case .bypassPermissions: "Every tool runs, nothing is checked"
        }
    }
}

/// The three switchers under the composer, together. They are flags on the
/// `claude` process, so changing one restarts it — see
/// ``ClaudeSession/apply(_:)``.
struct ClaudeSettings: Equatable {
    var model: ClaudeModel = .auto
    var effort: ClaudeEffort = .standard
    var permissionMode: ClaudePermissionMode = .auto

    private static let defaultsKey = "workspace.claude.settings"

    /// Remembered window-wide: the way you like to work with Claude does not
    /// change from one repository to the next.
    static func restored() -> ClaudeSettings {
        let stored = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String] ?? [:]
        var settings = ClaudeSettings()
        if let value = stored["model"], let model = ClaudeModel(rawValue: value) {
            settings.model = model
        }
        if let value = stored["effort"], let effort = ClaudeEffort(rawValue: value) {
            settings.effort = effort
        }
        if let value = stored["mode"], let mode = ClaudePermissionMode(rawValue: value) {
            settings.permissionMode = mode
        }
        return settings
    }

    func persist() {
        UserDefaults.standard.set(
            [
                "model": model.rawValue,
                "effort": effort.rawValue,
                "mode": permissionMode.rawValue,
            ],
            forKey: Self.defaultsKey
        )
    }
}
