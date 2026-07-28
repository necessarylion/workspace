import Foundation

/// Making a repository, rather than going looking for one that already exists.
///
/// Two ways in, and both end in a folder on disk that
/// ``WorkspaceStore/addProject(at:makeSelected:)`` takes like any other: an
/// empty repository from nothing (`git init`), and a copy of one that is already
/// on a host (`git clone`). Everything runs through ``Shell``, so the `git` used
/// here is the one the user's own prompt would find.
enum NewRepository {
    /// Which of the two the sheet is doing.
    enum Mode: String, CaseIterable, Identifiable {
        case create, clone

        var id: String { rawValue }

        var title: String {
            switch self {
            case .create: "New"
            case .clone: "Clone"
            }
        }

        /// The button that finishes the sheet.
        var actionTitle: String {
            switch self {
            case .create: "Create Repository"
            case .clone: "Clone Repository"
            }
        }

        /// What it says while the command is running.
        var progressTitle: String {
            switch self {
            case .create: "Creating…"
            case .clone: "Cloning…"
            }
        }
    }

    enum Failure: LocalizedError {
        case noName
        case badName(String)
        case noRemote
        case occupied(URL)
        case alreadyARepository(URL)
        case couldNotCreate(URL, String)
        /// git's own words. Whatever it said is more use than anything we could
        /// say over the top of it.
        case git(String)

        var errorDescription: String? {
            switch self {
            case .noName:
                "Give the folder a name."
            case .badName(let name):
                "“\(name)” cannot be a folder name — it is a name, not a path."
            case .noRemote:
                "Paste the repository's SSH or HTTPS URL."
            case .occupied(let url):
                "\(url.lastPathComponent) already exists in \(url.deletingLastPathComponent().lastPathComponent), and it is not empty."
            case .alreadyARepository(let url):
                "\(url.lastPathComponent) is already a git repository. Add its folder instead."
            case .couldNotCreate(let url, let reason):
                "Could not make a folder in \(url.lastPathComponent) — \(reason)"
            case .git(let message):
                message.isEmpty ? "git could not do it." : message
            }
        }
    }

    // MARK: - Where it goes

    /// Where the sheet points to begin with: the folder the repositories already
    /// added share, since a new one nearly always joins them. `~/Developer` when
    /// this Mac has one and nothing has been added yet, and the home folder when
    /// it has not.
    static func suggestedParent(near existing: [URL]) -> URL {
        let manager = FileManager.default
        let home = manager.homeDirectoryForCurrentUser

        let parents = existing.map { $0.deletingLastPathComponent() }
        let byPath = Dictionary(grouping: parents, by: \.path)
        // Most repositories wins; the path breaks a tie, so the answer does not
        // move about between launches.
        let ranked = byPath.sorted {
            $0.value.count == $1.value.count ? $0.key < $1.key : $0.value.count > $1.value.count
        }
        if let common = ranked.first?.value.first { return common }

        let developer = home.appending(path: "Developer")
        var isDirectory: ObjCBool = false
        if manager.fileExists(atPath: developer.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return developer
        }
        return home
    }

    /// The URL out of whatever was pasted. The whole `git clone …` line comes
    /// along with it more often than not, and so do the quotes around a string
    /// copied out of a README.
    ///
    /// The line a README gives you carries more than the URL: options
    /// (`--depth 1`, `-b main`), which are not it, and a destination folder,
    /// which the sheet has a field of its own for. So the URL is picked out by
    /// what it looks like rather than by where it sits — the first word that is
    /// not an option and has a `:` or a `/` in it, which every remote does and
    /// neither `1` nor `main` nor a folder name does. A word that looks like
    /// nothing in particular is taken as typed, so a bare host alias still
    /// works.
    static func normalizedRemote(_ text: String) -> String {
        var line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.lowercased().hasPrefix("git clone ") {
            line = String(line.dropFirst("git clone ".count))
        }
        let quotes = CharacterSet(charactersIn: "\"'")
        let words = line
            .split(separator: " ")
            .map { $0.trimmingCharacters(in: quotes) }
            .filter { !$0.isEmpty && !$0.hasPrefix("-") }
        return words.first(where: isRemoteShaped) ?? words.first ?? ""
    }

    /// Whether a word from a pasted command could be the repository: every form
    /// git takes has a separator in it — `https://…`, `git@host:owner/repo`,
    /// `~/path`, `../path`. The value an option ate (`1`, `main`) and the
    /// destination folder do not.
    private static func isRemoteShaped(_ word: String) -> Bool {
        word.contains(":") || word.contains("/") || word.hasPrefix("~")
    }

    /// The folder a clone would land in — `git@github.com:owner/repo.git` gives
    /// `repo`. Empty while the URL box says nothing, which leaves the folder
    /// field showing its placeholder.
    static func folderName(forRemote text: String) -> String {
        let remote = normalizedRemote(text)
        guard !remote.isEmpty else { return "" }
        // The same parser the sidebar reads `origin` with, so an SSH alias and
        // Data Center's `/scm/` prefix are already handled.
        return RemoteInfo.parse(remoteURL: remote).slug
    }

    // MARK: - Making one

    /// `git init` in a new folder. Returns where it landed.
    static func create(named name: String, in parent: URL) async throws -> URL {
        let folder = try validated(name: name)
        let destination = parent.appending(path: folder)
        let made = try prepareEmptyFolder(at: destination, in: parent)

        // Whatever the user's own `git init` would call the first branch, and
        // `main` only when they have not said: passing `--initial-branch`
        // regardless would override a config that asks for something else.
        let configured = await Shell.run(
            ["git", "config", "--get", "init.defaultBranch"],
            in: parent,
            timeout: 15
        )
        var arguments = ["init"]
        if configured.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            arguments += ["--initial-branch", "main"]
        }

        var result = await Shell.run(["git"] + arguments, in: destination, timeout: 60)
        if !result.isSuccess, arguments.count > 1 {
            // A git older than 2.28 has no `--initial-branch`; its own default
            // is then the only branch on offer.
            result = await Shell.run(["git", "init"], in: destination, timeout: 60)
        }
        guard result.isSuccess else {
            // Only a folder this call made itself is taken back again.
            if made { discardMadeFolder(at: destination) }
            throw Failure.git(result.failureMessage)
        }
        return destination
    }

    /// `git clone` into a new folder beside the ones already added. Returns where
    /// it landed.
    static func clone(_ remoteText: String, named name: String, into parent: URL) async throws -> URL {
        let remote = normalizedRemote(remoteText)
        guard !remote.isEmpty else { throw Failure.noRemote }
        let folder = try validated(name: name)
        let destination = parent.appending(path: folder)

        // git makes the folder itself, so only an existing one is our business.
        // It would refuse a non-empty one too, but by naming a path rather than
        // saying what to do about it.
        try checkFree(destination)
        // git counts a folder holding a `.DS_Store` as occupied — `is_empty_dir`
        // sees every entry, dotfiles included — and refuses to clone into it.
        // `checkFree` has just said that file is the only thing there, and it is
        // Finder's note of how the window was scrolled, not anything of the
        // user's, so it goes rather than the clone failing on it.
        removeFinderMetadata(in: destination)
        try makeParent(parent)

        let result = await Shell.run(
            // `--` so a URL that begins with a dash cannot arrive as an option.
            ["git", "clone", "--", remote, folder],
            in: parent,
            // The one git command in the app as slow as the repository is big.
            timeout: 900,
            // There is no terminal to ask in: without this a private HTTPS URL
            // sits waiting for a username until the timeout runs out.
            environment: ["GIT_TERMINAL_PROMPT": "0"]
        )
        guard result.isSuccess else { throw Failure.git(explained(result.failureMessage)) }
        return destination
    }

    // MARK: - Checks

    private static func validated(name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Failure.noName }
        // A name, not a path: `..` and a slash would put the repository
        // somewhere other than the folder the sheet says it is going into.
        guard !trimmed.contains("/"), !trimmed.contains(":"), !trimmed.hasPrefix(".") else {
            throw Failure.badName(trimmed)
        }
        return trimmed
    }

    /// Nothing in the way at `destination`. A folder that exists but holds
    /// nothing is not in the way — that is where the user just pointed the
    /// picker's New Folder button.
    private static func checkFree(_ destination: URL) throws {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: destination.path, isDirectory: &isDirectory) else { return }
        guard isDirectory.boolValue else { throw Failure.occupied(destination) }
        guard !manager.fileExists(atPath: destination.appending(path: ".git").path) else {
            throw Failure.alreadyARepository(destination)
        }
        let contents = (try? manager.contentsOfDirectory(atPath: destination.path)) ?? []
        // `.DS_Store` is not something the user put there.
        guard contents.allSatisfy({ $0 == ".DS_Store" }) else { throw Failure.occupied(destination) }
    }

    /// Returns whether the folder had to be made, so a failed `git init` can
    /// take it away again without ever deleting one that was already there.
    private static func prepareEmptyFolder(at destination: URL, in parent: URL) throws -> Bool {
        try checkFree(destination)
        guard !FileManager.default.fileExists(atPath: destination.path) else { return false }
        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            return true
        } catch {
            throw Failure.couldNotCreate(parent, error.localizedDescription)
        }
    }

    /// Takes back a folder this call made a moment ago, when git then refused to
    /// make a repository in it.
    ///
    /// Only when nothing is in it but what git itself could have left half
    /// made. The folder was empty when it was created, but "empty" was true a
    /// few seconds ago and this is a recursive delete: anything that has
    /// arrived since belongs to whatever put it there, and losing it would be a
    /// far worse outcome than leaving an empty folder behind.
    private static func discardMadeFolder(at destination: URL) {
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: destination.path)) ?? []
        guard contents.allSatisfy({ $0 == ".git" || $0 == ".DS_Store" }) else { return }
        try? FileManager.default.removeItem(at: destination)
    }

    /// Drops the `.DS_Store` a folder made in Finder arrives with. Nothing when
    /// the folder does not exist, which is the usual case.
    private static func removeFinderMetadata(in destination: URL) {
        let metadata = destination.appending(path: ".DS_Store")
        guard FileManager.default.fileExists(atPath: metadata.path) else { return }
        try? FileManager.default.removeItem(at: metadata)
    }

    /// The folder the repository goes *into*. Chosen from a picker nearly always,
    /// so it is there — but a remembered one may have been moved since.
    private static func makeParent(_ parent: URL) throws {
        guard !FileManager.default.fileExists(atPath: parent.path) else { return }
        do {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        } catch {
            throw Failure.couldNotCreate(parent, error.localizedDescription)
        }
    }

    /// git's message, plus the line it leaves out. Both of these come up on a
    /// Mac that has never cloned from this host before, and neither reads as
    /// something the user can act on until it is said plainly.
    private static func explained(_ message: String) -> String {
        if message.contains("could not read Username") || message.contains("Authentication failed") {
            return """
            \(message)

            An HTTPS URL needs a credential helper that is signed in. The SSH URL for the same repository usually does not.
            """
        }
        if message.contains("Host key verification failed") {
            return """
            \(message)

            Connect to the host once from a terminal, so its key can be accepted, and clone again.
            """
        }
        return message
    }
}

/// One turn of the New Repository sheet. Its identity is per opening, so the
/// sheet starts empty each time rather than coming back with the URL half typed
/// from the time before.
struct NewRepositoryRequest: Identifiable {
    let id = UUID()
    let mode: NewRepository.Mode
}
