import Foundation

/// What happened to one path, reduced to the handful of verdicts everything
/// outside the change list draws from: the file tree colours a row by this, and
/// the letter the row wears comes from it.
///
/// **The order is the point.** A folder in the tree wears the strongest verdict
/// of anything inside it, and `Comparable` — synthesised from the order these
/// are declared in — is how "strongest" is decided. A folder holding one
/// conflict and twenty edits is a folder with a conflict in it.
enum GitChangeKind: Sendable, Hashable, Comparable {
    /// Staged as new, or not in git at all yet. One idea at two stages, and the
    /// tree has no room to say which — the change list beside it does.
    case added
    case renamed
    case modified
    case deleted
    case conflicted

    /// The one letter the tree puts at the end of a file's row, the way every
    /// editor with this feature does. A conflict is the exception: it is the
    /// one that wants noticing rather than reading.
    var letter: String {
        switch self {
        case .added: "A"
        case .renamed: "R"
        case .modified: "M"
        case .deleted: "D"
        case .conflicted: "!"
        }
    }

    /// What the row's tooltip says. Plain words, since the letter is the short
    /// form and this is the long one.
    var label: String {
        switch self {
        case .added: "Added"
        case .renamed: "Renamed"
        case .modified: "Modified"
        case .deleted: "Deleted"
        case .conflicted: "Conflicted"
        }
    }
}

/// A snapshot of `git status` for a repository.
struct GitStatus: Sendable, Hashable {
    struct Change: Sendable, Hashable, Identifiable {
        let code: String        // porcelain XY code, e.g. " M", "??"
        /// Where the file is now. For a rename or a copy that is the new name.
        let path: String
        /// The name a renamed or copied file had before, nil for everything else.
        var originalPath: String?
        var id: String { path }

        /// The seven codes git writes for a path it could not merge. They have
        /// to be read as a pair: "AA" and "DD" carry no `U`, so a per-letter
        /// test called them a plain add and a plain delete.
        private static let conflictCodes: Set<String> = ["DD", "AU", "UD", "UA", "DU", "AA", "UU"]

        /// A merge left this path with its three stages still in the index.
        var isConflicted: Bool { Self.conflictCodes.contains(code) }

        var isStaged: Bool {
            // A conflict is neither staged nor unstaged, whatever its first
            // letter looks like. Calling it staged put it in the pile whose
            // buttons are `git restore --staged` and `git commit` — the first
            // drops the merge stages and silently keeps our side, the second
            // git refuses outright.
            guard !isConflicted, let first = code.first else { return false }
            return first != " " && first != "?"
        }

        /// Which of the two porcelain letters describes this row: the index side
        /// when the change is staged, the working tree side otherwise. Reading
        /// the pair as a whole missed the mixed codes — "RM", "AM", "MD" — and
        /// left the raw letters on screen. Conflicts never reach here; they are
        /// named by the pair.
        private var statusLetter: Character? {
            guard let index = code.first else { return nil }
            if index == "?" { return "?" }
            return isStaged ? index : code.dropFirst().first ?? " "
        }

        /// Who did what, in git's own words. A conflict is two changes, not
        /// one, so "Added" alone would not say whose side added.
        private var conflictLabel: String {
            switch code {
            case "DD": "Both Deleted"
            case "AA": "Both Added"
            case "AU": "Added by Us"
            case "UA": "Added by Them"
            case "DU": "Deleted by Us"
            case "UD": "Deleted by Them"
            default: "Both Modified"
            }
        }

        var label: String {
            if isConflicted { return conflictLabel }
            switch statusLetter {
            case "M": return "Modified"
            case "A": return "Added"
            case "D": return "Deleted"
            case "R": return "Renamed"
            case "C": return "Copied"
            case "T": return "Type Changed"
            case "?": return "Untracked"
            default: return code.trimmingCharacters(in: .whitespaces)
            }
        }

        /// The same verdict as ``label``, in the form the tree and the gutter
        /// colour from. Read off the porcelain letter rather than off `label`,
        /// so a wording change up there cannot quietly repaint the tree.
        ///
        /// A copy counts as an addition: what the tree is showing is a file
        /// that was not there before. A type change counts as a modification,
        /// which is what it is — the path stayed, its contents did not.
        var kind: GitChangeKind {
            if isConflicted { return .conflicted }
            switch statusLetter {
            case "A", "?", "C": return .added
            case "R": return .renamed
            case "D": return .deleted
            default: return .modified
            }
        }

        var symbol: String {
            if isConflicted { return "exclamationmark.triangle.fill" }
            switch label {
            case "Modified": return "pencil.circle.fill"
            case "Added": return "plus.circle.fill"
            case "Deleted": return "minus.circle.fill"
            case "Renamed", "Copied": return "arrow.right.circle.fill"
            case "Type Changed": return "arrow.triangle.2.circlepath.circle.fill"
            // The same plus a staged new file wears, hollow. One file arriving
            // is one idea at two stages, and a question mark said neither of
            // them — it read as "git is unsure about this", when the file is
            // simply new and not staged yet.
            case "Untracked": return "plus.circle"
            default: return "circle.fill"
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
    /// Whether the branch has anything committed on it. False only for a
    /// repository still on its first commit, which is a state several git
    /// commands cannot be asked about at all: there is no `HEAD` to resolve.
    var hasCommits: Bool = true

    var isClean: Bool { changes.isEmpty }

    /// How git names the branch of a repository that has nothing committed yet.
    /// It called that "Initial commit on" until 2.16, and the app runs whatever
    /// git the user's own prompt finds, so both spellings are read.
    private static let noCommitsPrefixes = ["No commits yet on ", "Initial commit on "]

    /// Runs `git status`; nil when the folder is not a repository.
    static func load(for directory: URL) async -> GitStatus? {
        async let ignoredTask = loadIgnored(in: directory)
        // `-z` because the plain form is not a format paths survive: git
        // C-quotes anything with a space or a non-ASCII character in it, and
        // writes a rename as the single field "old -> new". Neither string is
        // a pathspec git will take back, so `git add` and `git restore` failed
        // on exactly those files. With `-z` each path is its own NUL-terminated
        // field, verbatim, and a rename simply adds a second one.
        //
        // `-uall` because git's default is to collapse a folder with nothing
        // tracked in it down to the folder — `?? server/` — which is one row
        // standing for any number of files. The list is a list of files: every
        // other row is one, the diff of a folder is not something `git diff`
        // will produce, and staging or discarding it moved more than the row
        // named. `.gitignore` is applied either way, so this does not go
        // walking into a `node_modules`.
        let result = await Shell.run(
            ["git", "status", "--porcelain=v1", "--branch", "-z", "-uall"],
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
        var hasCommits = true

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
                let name = rest.components(separatedBy: "...").first ?? rest
                // A repository with nothing committed yet says so instead of
                // naming the branch on its own — "## No commits yet on main" —
                // and a brand new one is exactly what the New Repository sheet
                // leaves behind. A detached head has a phrase of its own too,
                // and `detached` is the word the rest of the app uses for it.
                if name == "HEAD (no branch)" {
                    branch = "detached"
                } else if let prefix = Self.noCommitsPrefixes.first(where: name.hasPrefix) {
                    branch = String(name.dropFirst(prefix.count))
                    hasCommits = false
                } else {
                    branch = name
                }
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
            ignored: await ignoredTask,
            hasCommits: hasCommits
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

    /// The repository's own root, which is not always the folder that was
    /// added.
    ///
    /// A package of a monorepo is a perfectly reasonable thing to open, and
    /// `git status` answers from anywhere inside a repository — so the app
    /// never had to notice the difference. The diff did: every path git
    /// *reports* (`--porcelain`, `ls-files`) is relative to the root, while a
    /// pathspec and a `--no-index` argument are read from wherever the command
    /// ran. Open `apps/web` and `git diff HEAD -- apps/web/src/x.spec.ts`
    /// matched nothing at all, which arrived as a file with no changes in it.
    ///
    /// Falls back to the folder itself, which is both the answer for a plain
    /// checkout and the only sensible one when this is not a repository.
    static func root(of directory: URL) async -> URL {
        let result = await Shell.run(
            ["git", "rev-parse", "--show-toplevel"],
            in: directory,
            timeout: 15
        )
        let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.isSuccess, !path.isEmpty else { return directory }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// Unified diff for one change (working tree, including staged changes).
    /// Takes every path the change covers, so a rename is shown as the one move
    /// it is rather than as a new file with no history.
    ///
    /// Run from the repository root rather than from `directory`, because the
    /// paths handed in came from `git status --porcelain` and are relative to
    /// it — see ``root(of:)``.
    static func diff(paths: [String], in directory: URL, isUntracked: Bool) async -> String {
        guard let first = paths.first else { return "" }
        let root = await root(of: directory)
        if isUntracked {
            // Untracked files have no diff; synthesise one against /dev/null.
            let result = await Shell.run(
                ["git", "diff", "--no-index", "--", "/dev/null", first],
                in: root,
                timeout: 30
            )
            return result.stdout
        }
        let base = await baseRevision(in: root)
        let result = await Shell.run(["git", "diff", base, "--"] + paths, in: root, timeout: 30)
        return result.stdout
    }

    /// What a working tree is measured against: `HEAD` once the branch has a
    /// commit on it, and the empty tree before that.
    ///
    /// `git diff HEAD` is not a question a repository still on its first commit
    /// can be asked — `fatal: bad revision 'HEAD'` — so a file staged in a
    /// brand new repository arrived in the viewer with nothing in it. The empty
    /// tree is the same question with the answer git would give if that commit
    /// existed and were empty, which keeps a deletion a deletion rather than
    /// making every path a new file. It is asked for rather than written down
    /// because the hash depends on the repository's hash algorithm.
    private static func baseRevision(in root: URL) async -> String {
        let head = await Shell.run(
            ["git", "rev-parse", "--verify", "--quiet", "HEAD"],
            in: root,
            timeout: 15
        )
        if head.isSuccess, !head.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "HEAD"
        }
        let empty = await Shell.run(
            ["git", "hash-object", "-t", "tree", "/dev/null"],
            in: root,
            timeout: 15
        )
        let hash = empty.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return hash.isEmpty ? "HEAD" : hash
    }

    /// Unified diff for the whole working tree (staged and unstaged), with
    /// synthesised entries appended for untracked files so they show up too.
    static func diffAll(in directory: URL, untrackedPaths: [String]) async -> String {
        // The untracked paths are root-relative for the same reason, and
        // `--no-index` reads them as plain file names.
        let root = await root(of: directory)
        let base = await baseRevision(in: root)
        var text = await Shell.run(["git", "diff", base], in: root, timeout: 30).stdout
        for path in untrackedPaths {
            let result = await Shell.run(
                ["git", "diff", "--no-index", "--", "/dev/null", path],
                in: root,
                timeout: 30
            )
            if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
            text += result.stdout
        }
        return text
    }
}
