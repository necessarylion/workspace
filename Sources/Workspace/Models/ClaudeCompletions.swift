import Foundation

/// A `/command` the chat can offer.
struct ClaudeSlashCommand: Identifiable, Sendable, Equatable {
    enum Source: Sendable {
        /// `.claude/commands` inside the repository — the ones a team checks in.
        case project
        /// `~/.claude/commands` — your own, in every repository.
        case user
        /// Everything else the CLI reports: its built-ins, and whatever plugins
        /// and MCP servers add.
        case builtIn
    }

    let name: String
    var detail: String
    var source: Source

    var id: String { name }
}

/// What the composer completes: `/commands` and `@files`.
///
/// Both lists are wanted before a single prompt has been sent, so neither waits
/// on the `claude` process. The commands are read off disk the way the CLI
/// reads them, and once a process *has* started, what it reports in its `init`
/// is merged in — that is where the built-ins and anything a plugin adds come
/// from, and nothing else can know about those.
enum ClaudeCompletions {
    // MARK: - Slash commands

    /// The commands defined as files: the repository's, then your own.
    static func commands(for project: URL) async -> [ClaudeSlashCommand] {
        let projectFolder = project.appendingPathComponent(".claude/commands", isDirectory: true)
        let userFolder = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/commands", isDirectory: true)

        return await Task.detached(priority: .utility) {
            let fromProject = read(projectFolder, source: .project)
            let fromUser = read(userFolder, source: .user)
            // A repository's command wins over one of yours by the same name,
            // which is the order the CLI resolves them in.
            let taken = Set(fromProject.map(\.name))
            return (fromProject + fromUser.filter { !taken.contains($0.name) })
                .sorted { $0.name < $1.name }
        }.value
    }

    private static let builtInsKey = "workspace.claude.builtInCommands"

    /// What the ones worth naming actually do. The CLI reports its commands by
    /// name alone, so a description has to come from here or from nowhere.
    private static let descriptions: [String: String] = [
        "mcp": "Which MCP servers are connected",
        "usage": "How much of your subscription is left",
        "context": "How full the context window is",
        "model": "Which model is answering — `/model sonnet` changes it",
        "effort": "How hard it thinks — `/effort high`",
        "compact": "Summarise the conversation so far to free up context",
        "init": "Write a CLAUDE.md for this repository",
        "review": "Review a pull request",
        "security-review": "Review the current changes for security problems",
        "agents": "The subagents available here",
        "cost": "What this conversation has cost",
        "insights": "What Claude Code has been doing lately",
        "recap": "Recap what has happened in this conversation",
    ]

    /// Commands the CLI has but that have no place in this window.
    ///
    /// `clear` is the dangerous one: it would empty the CLI's memory of the
    /// conversation while the transcript on screen still showed it, and the two
    /// would silently disagree from then on — *New Conversation* is the honest
    /// way to do that here. The rest either want a terminal UI to answer in or
    /// refuse to run outside one, which was checked against the real CLI rather
    /// than guessed.
    private static let unavailable: Set<String> = [
        "clear", "resume", "config", "doctor", "heapdump", "color", "rename", "fast",
    ]

    /// The ones offered before any `claude` has run — every one verified to
    /// answer for real in this mode, so the menu is useful from the first `/`
    /// rather than only after the first prompt.
    static let defaultBuiltIns = [
        "mcp", "usage", "context", "model", "effort", "compact",
        "init", "review", "security-review",
    ]

    /// Names into commands, with what we know about them attached and the ones
    /// that do not belong here dropped.
    static func builtIns(named names: [String]) -> [ClaudeSlashCommand] {
        names
            .filter { !unavailable.contains($0) && !$0.hasPrefix("__") }
            .map {
                ClaudeSlashCommand(name: $0, detail: descriptions[$0] ?? "", source: .builtIn)
            }
    }

    /// The built-in and plugin commands learned from a previous run, or the
    /// defaults until there has been one.
    ///
    /// Only a running `claude` can say what it actually has, and it says so in
    /// the `init` of its first turn. They do not belong to a repository, so one
    /// list serves every one of them.
    static func rememberedBuiltIns() -> [ClaudeSlashCommand] {
        let names = UserDefaults.standard.stringArray(forKey: builtInsKey) ?? []
        return builtIns(named: names.isEmpty ? defaultBuiltIns : names)
    }

    static func remember(builtIns names: [String]) {
        guard !names.isEmpty else { return }
        UserDefaults.standard.set(names.sorted(), forKey: builtInsKey)
    }

    /// Every `.md` under a commands folder. A file in a subfolder is namespaced
    /// with a colon — `commands/frontend/build.md` is `/frontend:build` — which
    /// is the CLI's own naming.
    private static func read(_ folder: URL, source: ClaudeSlashCommand.Source) -> [ClaudeSlashCommand] {
        let manager = FileManager.default
        guard let walker = manager.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var commands: [ClaudeSlashCommand] = []
        for case let file as URL in walker where file.pathExtension == "md" {
            // The extension comes off the path rather than out of the string:
            // a folder called `notes.md` would otherwise lose its name too.
            let relative = file.deletingPathExtension().path.dropFirst(folder.path.count + 1)
            let name = relative.replacingOccurrences(of: "/", with: ":")
            guard !name.isEmpty else { continue }
            commands.append(
                ClaudeSlashCommand(name: name, detail: description(of: file), source: source)
            )
        }
        return commands
    }

    /// The `description:` from the file's frontmatter, which is what the CLI
    /// shows beside a command. Falls back to its first line of prose.
    private static func description(of file: URL) -> String {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return "" }
        var inFrontmatter = false
        var firstProse = ""

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" {
                if inFrontmatter { break }
                inFrontmatter = true
                continue
            }
            if inFrontmatter, trimmed.lowercased().hasPrefix("description:") {
                return trimmed.dropFirst("description:".count)
                    .trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
            }
            if !inFrontmatter, firstProse.isEmpty, !trimmed.isEmpty, !trimmed.hasPrefix("#") {
                firstProse = trimmed
            }
        }
        return firstProse.count > 80 ? String(firstProse.prefix(80)) + "…" : firstProse
    }

    // MARK: - Files

    /// Every file in the repository, as paths relative to it.
    ///
    /// `git ls-files` rather than walking the folder: it is one call however
    /// deep the tree is, and it already leaves out what `.gitignore` covers —
    /// completing `@node_modules/…` would bury the files actually worked on. A
    /// folder that is not a repository falls back to a walk.
    static func files(in project: URL) async -> [String] {
        let listed = await Shell.run(
            ["git", "ls-files", "--cached", "--others", "--exclude-standard"],
            in: project,
            timeout: 20
        )
        if listed.isSuccess {
            let paths = listed.stdout
                .split(separator: "\n")
                .map(String.init)
                .filter { !$0.isEmpty }
            if !paths.isEmpty { return paths }
        }
        return await walk(project)
    }

    private static let skippedFolders: Set<String> = [
        ".git", ".build", ".swiftpm", "node_modules", "DerivedData", ".next", "dist",
    ]

    private static func walk(_ project: URL) async -> [String] {
        await Task.detached(priority: .utility) { walkSync(project) }.value
    }

    /// Synchronous on purpose: a directory enumerator cannot be stepped from an
    /// async context, so the walk happens whole inside the detached task.
    private static func walkSync(_ project: URL) -> [String] {
        let manager = FileManager.default
        guard let walker = manager.enumerator(
            at: project,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var paths: [String] = []
        let root = project.standardizedFileURL.path + "/"
        for case let url as URL in walker {
            if skippedFolders.contains(url.lastPathComponent) {
                walker.skipDescendants()
                continue
            }
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard !isDirectory else { continue }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(root) else { continue }
            paths.append(String(path.dropFirst(root.count)))
            // A tree with a hundred thousand files is not one anybody picks
            // a completion out of, and the list has to stay cheap to filter.
            if paths.count >= 20_000 { break }
        }
        return paths
    }

    // Matching lives in `FileFinder`, which both the chat's `@` menu and ⌘P
    // rank with. It folds a repository's paths to bytes once when the list is
    // read, so a keystroke only ever compares — the string-by-string version
    // that used to live here lowercased all twenty thousand of them again on
    // every letter typed, on the main actor.
}
