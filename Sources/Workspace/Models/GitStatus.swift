import Foundation

/// A snapshot of `git status` for a repository.
struct GitStatus: Sendable, Hashable {
    struct Change: Sendable, Hashable, Identifiable {
        let code: String        // porcelain XY code, e.g. " M", "??"
        let path: String
        var id: String { path }

        var isStaged: Bool {
            guard let first = code.first else { return false }
            return first != " " && first != "?"
        }

        var label: String {
            switch code.trimmingCharacters(in: .whitespaces) {
            case "M", "MM": "Modified"
            case "A", "AM": "Added"
            case "D": "Deleted"
            case "R": "Renamed"
            case "??": "Untracked"
            case "UU": "Conflict"
            default: code.trimmingCharacters(in: .whitespaces)
            }
        }

        var symbol: String {
            switch label {
            case "Modified": "pencil.circle.fill"
            case "Added": "plus.circle.fill"
            case "Deleted": "minus.circle.fill"
            case "Renamed": "arrow.right.circle.fill"
            case "Untracked": "questionmark.circle.fill"
            case "Conflict": "exclamationmark.triangle.fill"
            default: "circle.fill"
            }
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
        let result = await Shell.run(
            ["git", "status", "--porcelain=v1", "--branch"],
            in: directory,
            timeout: 30
        )
        guard result.isSuccess else {
            _ = await ignoredTask
            return nil
        }

        var branch = "detached"
        var ahead = 0
        var behind = 0
        var changes: [Change] = []

        for line in result.stdout.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("##") {
                // "## main...origin/main [ahead 1, behind 2]"
                var rest = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
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
            } else if line.count > 3 {
                changes.append(Change(code: String(line.prefix(2)), path: String(line.dropFirst(3))))
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

    /// Unified diff for one path (working tree, including staged changes).
    static func diff(path: String, in directory: URL, isUntracked: Bool) async -> String {
        if isUntracked {
            // Untracked files have no diff; synthesise one against /dev/null.
            let result = await Shell.run(
                ["git", "diff", "--no-index", "--", "/dev/null", path],
                in: directory,
                timeout: 30
            )
            return result.stdout
        }
        let result = await Shell.run(["git", "diff", "HEAD", "--", path], in: directory, timeout: 30)
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
