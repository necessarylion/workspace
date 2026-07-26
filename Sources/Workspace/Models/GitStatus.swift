import Foundation

/// A snapshot of `git status` for a repository.
struct GitStatus: Sendable, Hashable {
    struct Change: Sendable, Hashable, Identifiable {
        let code: String        // porcelain XY code, e.g. " M", "??"
        /// Where the file is now. For a rename or a copy that is the new name.
        let path: String
        /// The name a renamed or copied file had before, nil for everything else.
        var originalPath: String?
        var id: String { path }

        var isStaged: Bool {
            guard let first = code.first else { return false }
            return first != " " && first != "?"
        }

        /// Which of the two porcelain letters describes this row: the index side
        /// when the change is staged, the working tree side otherwise. Reading
        /// the pair as a whole missed the mixed codes — "RM", "AM", "MD" — and
        /// left the raw letters on screen.
        private var statusLetter: Character? {
            guard let index = code.first else { return nil }
            let worktree = code.dropFirst().first ?? " "
            if index == "?" { return "?" }
            if index == "U" || worktree == "U" { return "U" }
            return isStaged ? index : worktree
        }

        var label: String {
            switch statusLetter {
            case "M": "Modified"
            case "A": "Added"
            case "D": "Deleted"
            case "R": "Renamed"
            case "C": "Copied"
            case "T": "Type Changed"
            case "?": "Untracked"
            case "U": "Conflict"
            default: code.trimmingCharacters(in: .whitespaces)
            }
        }

        var symbol: String {
            switch label {
            case "Modified": "pencil.circle.fill"
            case "Added": "plus.circle.fill"
            case "Deleted": "minus.circle.fill"
            case "Renamed", "Copied": "arrow.right.circle.fill"
            case "Type Changed": "arrow.triangle.2.circlepath.circle.fill"
            case "Untracked": "questionmark.circle.fill"
            case "Conflict": "exclamationmark.triangle.fill"
            default: "circle.fill"
            }
        }

        /// How the change reads to a person: a rename names both ends, anything
        /// else just names itself.
        var displayPath: String {
            if let originalPath, originalPath != path { return "\(originalPath) → \(path)" }
            return path
        }

        /// Every path a git command has to be handed for this change. A rename
        /// is two index entries — the old name gone, the new name added — so
        /// naming only one of them stages or unstages half of it.
        var gitPaths: [String] {
            if let originalPath, originalPath != path { return [originalPath, path] }
            return [path]
        }
    }

    var branch: String
    var ahead: Int
    var behind: Int
    var changes: [Change]
    /// Paths `.gitignore` covers, relative to the root and without a trailing
    /// slash. Git collapses a wholly ignored folder to the folder itself, so
    /// this stays short even next to a `node_modules`.
    var ignored: Set<String> = []

    var isClean: Bool { changes.isEmpty }

    /// Runs `git status`; nil when the folder is not a repository.
    static func load(for directory: URL) async -> GitStatus? {
        async let ignoredTask = loadIgnored(in: directory)
        // `-z` because the plain form is not a format paths survive: git
        // C-quotes anything with a space or a non-ASCII character in it, and
        // writes a rename as the single field "old -> new". Neither string is
        // a pathspec git will take back, so `git add` and `git restore` failed
        // on exactly those files. With `-z` each path is its own NUL-terminated
        // field, verbatim, and a rename simply adds a second one.
        let result = await Shell.run(
            ["git", "status", "--porcelain=v1", "--branch", "-z"],
            in: directory,
            timeout: 30,
            // Reading the status normally rewrites `.git/index` to cache the
            // stat information it just gathered. That write looks exactly like
            // a checkout to `GitDirectoryWatcher`, which would then ask for
            // another status — so this read is told to touch nothing.
            environment: ["GIT_OPTIONAL_LOCKS": "0"]
        )
        guard result.isSuccess else {
            _ = await ignoredTask
            return nil
        }

        var branch = "detached"
        var ahead = 0
        var behind = 0
        var changes: [Change] = []

        let fields = result.stdout.components(separatedBy: "\0")
        var index = 0
        while index < fields.count {
            let field = fields[index]
            index += 1
            if field.hasPrefix("##") {
                // "## main...origin/main [ahead 1, behind 2]"
                var rest = field.dropFirst(2).trimmingCharacters(in: .whitespaces)
                if let bracket = rest.firstIndex(of: "[") {
                    let tracking = rest[rest.index(after: bracket)...].dropLast()
                    for part in tracking.split(separator: ",") {
                        let piece = part.trimmingCharacters(in: .whitespaces)
                        if piece.hasPrefix("ahead") {
                            ahead = Int(piece.dropFirst(6).trimmingCharacters(in: .whitespaces)) ?? 0
                        } else if piece.hasPrefix("behind") {
                            behind = Int(piece.dropFirst(7).trimmingCharacters(in: .whitespaces)) ?? 0
                        }
                    }
                    rest = String(rest[rest.startIndex..<bracket]).trimmingCharacters(in: .whitespaces)
                }
                branch = rest.components(separatedBy: "...").first ?? rest
            } else if field.count > 3 {
                let code = String(field.prefix(2))
                var originalPath: String?
                // A rename or a copy spends the very next field on the name the
                // file used to have. The letter can sit on either side of the
                // code, so both are worth checking.
                if code.contains("R") || code.contains("C"), index < fields.count {
                    originalPath = fields[index]
                    index += 1
                }
                changes.append(
                    Change(code: code, path: String(field.dropFirst(3)), originalPath: originalPath)
                )
            }
        }

        return GitStatus(
            branch: branch,
            ahead: ahead,
            behind: behind,
            changes: changes,
            ignored: await ignoredTask
        )
    }

    /// What `.gitignore` covers. `--directory` stops this from listing every
    /// file under `node_modules`; the tree only needs the folder itself.
    private static func loadIgnored(in directory: URL) async -> Set<String> {
        let result = await Shell.run(
            [
                "git", "ls-files", "--others", "--ignored", "--exclude-standard",
                "--directory", "--no-empty-directory",
            ],
            in: directory,
            timeout: 30
        )
        guard result.isSuccess else { return [] }
        return Set(
            result.stdout
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map { $0.hasSuffix("/") ? String($0.dropLast()) : String($0) }
        )
    }

    /// Unified diff for one change (working tree, including staged changes).
    /// Takes every path the change covers, so a rename is shown as the one move
    /// it is rather than as a new file with no history.
    static func diff(paths: [String], in directory: URL, isUntracked: Bool) async -> String {
        guard let first = paths.first else { return "" }
        if isUntracked {
            // Untracked files have no diff; synthesise one against /dev/null.
            let result = await Shell.run(
                ["git", "diff", "--no-index", "--", "/dev/null", first],
                in: directory,
                timeout: 30
            )
            return result.stdout
        }
        let result = await Shell.run(["git", "diff", "HEAD", "--"] + paths, in: directory, timeout: 30)
        return result.stdout
    }

    /// Unified diff for the whole working tree (staged and unstaged), with
    /// synthesised entries appended for untracked files so they show up too.
    static func diffAll(in directory: URL, untrackedPaths: [String]) async -> String {
        var text = await Shell.run(["git", "diff", "HEAD"], in: directory, timeout: 30).stdout
        for path in untrackedPaths {
            let result = await Shell.run(
                ["git", "diff", "--no-index", "--", "/dev/null", path],
                in: directory,
                timeout: 30
            )
            if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
            text += result.stdout
        }
        return text
    }
}
