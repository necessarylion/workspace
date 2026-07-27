import Foundation

/// One person asked to review a pull request, and where they stand on it.
///
/// GitHub keeps two lists — who has been asked (`reviewRequests`) and who has
/// answered (`latestReviews`) — while Bitbucket keeps one list of reviewers and
/// hangs each verdict off it. To a reviewer they are the same thing: a name, a
/// face, and whether that person has approved yet.
struct PullRequestReviewer: Identifiable, Sendable, Hashable {
    enum State: String, Sendable {
        case approved
        case changesRequested
        /// Reviewed without a verdict either way — GitHub's "commented".
        case commented
        /// Asked, and yet to say anything.
        case pending

        var title: String {
            switch self {
            case .approved: "Approved"
            case .changesRequested: "Changes requested"
            case .commented: "Commented"
            case .pending: "Not reviewed yet"
            }
        }

        var symbol: String {
            switch self {
            case .approved: "checkmark.circle.fill"
            case .changesRequested: "exclamationmark.bubble.fill"
            case .commented: "text.bubble.fill"
            case .pending: "clock.fill"
            }
        }

        /// Every host spells these differently, and one of them spells the
        /// absence of a verdict as "UNAPPROVED" — which carries the word
        /// "approve" inside it, so that one has to be ruled out first.
        static func parse(_ raw: String?) -> State {
            guard let raw = raw?.uppercased(), !raw.isEmpty else { return .pending }
            if raw.contains("CHANGES") || raw.contains("NEEDS_WORK")
                || raw.contains("NEEDSWORK") || raw.contains("DECLINE") {
                return .changesRequested
            }
            if raw.contains("UNAPPROVE") { return .pending }
            if raw.contains("APPROVE") { return .approved }
            if raw.contains("COMMENT") { return .commented }
            return .pending
        }
    }

    /// What the host's CLI takes when this person is added: a login on GitHub, a
    /// username or a `{uuid}` on Bitbucket. Not always what is shown.
    var handle: String
    /// The name to show — the handle wherever there is one, so a Bitbucket
    /// repository reads the way a GitHub one does.
    var name: String
    var avatarURL: URL?
    var state: State
    /// A team on GitHub, a reviewer group on Bitbucket Data Center: asked as one
    /// name, with no single face behind it.
    var isGroup = false

    var id: String { handle.isEmpty ? name : handle }
}

/// Someone who could be asked — one row of the reviewer picker.
struct ReviewerCandidate: Identifiable, Sendable, Hashable {
    /// The handle the host's CLI takes, as in ``PullRequestReviewer/handle``.
    var handle: String
    var name: String
    /// The person's full name, when the host sends one beside the handle.
    var detail: String?
    var avatarURL: URL?
    /// Bitbucket Cloud's `account_id`, which is how a mention names somebody
    /// there — the handle is a `{uuid}`, and the two are not the same string.
    /// Nothing else has one.
    var accountID: String?
    /// How close to this repository the host found them — 0 for the people who
    /// have worked on it or are meant to review it, higher for a name that came
    /// out of a workspace or an instance directory. It is what sorts the list, so
    /// that a workspace of eighty people still opens on the handful who review
    /// this repository.
    var relevance = 0

    var id: String { handle }

    /// How this person is written **in the box you are typing in**: `@` and the
    /// name, on every host.
    ///
    /// It is not always what the host is sent — see ``mention(on:)`` — because
    /// on Bitbucket Cloud the two are not the same string, and the id is no use
    /// to the person writing the comment. Picking a name out of a list only to
    /// watch `@{712020:297e58ad-1233-…}` land in the text reads as a bug, and
    /// leaves you unable to tell at a glance who you just named.
    var mentionDisplay: String { "@\(name)" }

    /// How this person is written inside a comment for the host to turn into a
    /// real mention — and it is not the same thing as the handle that asks them
    /// to review.
    ///
    /// GitHub takes the login. Bitbucket Cloud takes an id in braces,
    /// `@{712020:297e58ad-…}`: its raw Markdown never carries a username, which
    /// is the whole reason ``BitbucketMarkup`` exists. Data Center has no ids
    /// and takes the username itself.
    ///
    /// This is applied on the way out, by
    /// ``BitbucketMarkup/encodingMentions(in:people:)``, rather than typed —
    /// so the box keeps the name and the host still gets the id.
    func mention(on host: GitHostKind) -> String {
        guard host == .bitbucket else { return "@\(handle)" }
        if let accountID, !accountID.isEmpty { return "@{\(accountID)}" }
        // A Cloud handle is already `{uuid}`, so it needs no braces of its own;
        // a Data Center one is a plain username.
        return "@\(handle)"
    }

    /// Whether this person matches what has been typed into the picker's box.
    /// The handle and the full name are both searched: on Bitbucket the handle
    /// is often an id nobody knows by heart.
    func matches(_ query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return true }
        return name.lowercased().contains(needle)
            || handle.lowercased().contains(needle)
            || (detail?.lowercased().contains(needle) ?? false)
    }
}

extension Array where Element == PullRequestReviewer {
    var approvedCount: Int { lazy.filter { $0.state == .approved }.count }

    var hasChangesRequested: Bool { contains { $0.state == .changesRequested } }

    /// Whether everyone who was asked has approved. False on an empty list:
    /// nobody asked is not the same as everybody agreed.
    var isFullyApproved: Bool { !isEmpty && approvedCount == count }

    /// "2 of 3 approved" — what the summary bar's badge spells out on hover, and
    /// what the reviewer sheet puts at the top.
    var approvalSummary: String {
        isEmpty
            ? "No reviewers yet"
            : "\(approvedCount) of \(count) approved"
    }

    /// Verdicts first, so the people still to answer sit at the end of the row.
    var byStanding: [PullRequestReviewer] {
        func rank(_ state: PullRequestReviewer.State) -> Int {
            switch state {
            case .changesRequested: 0
            case .approved: 1
            case .commented: 2
            case .pending: 3
            }
        }
        return sorted { lhs, rhs in
            let left = rank(lhs.state)
            let right = rank(rhs.state)
            if left != right { return left < right }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }
}

extension PullRequestService {

    // MARK: - Who is reviewing

    static func reviewers(for pr: PullRequest, in directory: URL) async throws -> [PullRequestReviewer] {
        let found: [PullRequestReviewer]
        switch pr.host {
        case .github: found = try await gitHubReviewers(for: pr, in: directory)
        case .bitbucket: found = try await bitbucketReviewers(for: pr, in: directory)
        case .unknown: throw PullRequestError.unsupportedHost
        }
        // Whoever opened the pull request is not one of its reviewers, and
        // counting them would make "2 of 3 approved" read wrong. GitHub keeps
        // them out of both its lists; Bitbucket puts the author among the
        // participants, which is where this earns its keep.
        return found.filter { reviewer in
            reviewer.name.caseInsensitiveCompare(pr.author) != .orderedSame
                && reviewer.handle.caseInsensitiveCompare(pr.author) != .orderedSame
        }
    }

    /// Asks the host to add reviewers. Both CLIs take the whole list in one
    /// call, so either everybody is added or nobody is.
    static func addReviewers(
        _ handles: [String],
        to pr: PullRequest,
        in directory: URL
    ) async throws {
        let cleaned = handles
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !cleaned.isEmpty else {
            throw PullRequestError.commandFailed("Pick at least one person to review this.")
        }

        switch pr.host {
        case .github:
            var arguments = ["pr", "edit", "\(pr.number)"]
            for handle in cleaned { arguments += ["--add-reviewer", handle] }
            let result = await GitHubCLI.run(arguments, in: directory, timeout: 60)
            guard result.isSuccess else {
                throw PullRequestError.commandFailed(result.failureMessage)
            }

        case .bitbucket:
            var flags: [String] = []
            for handle in cleaned { flags += ["--reviewer", handle] }
            // Same dance as everywhere else: name the repository outright, and
            // fall back to whatever context bkt is configured with.
            var attempts: [[String]] = []
            let base = ["bkt", "pr", "edit", "\(pr.number)"] + flags
            if !pr.repositoryOwner.isEmpty, !pr.repositorySlug.isEmpty {
                attempts.append(base + ["--workspace", pr.repositoryOwner, "--repo", pr.repositorySlug])
                attempts.append(base + ["--project", pr.repositoryOwner, "--repo", pr.repositorySlug])
            }
            attempts.append(base)

            var lastMessage = "Bitbucket refused the reviewers."
            for command in attempts {
                let result = await Shell.run(command, in: directory, timeout: 60)
                if result.isSuccess { return }
                lastMessage = result.failureMessage
            }
            throw PullRequestError.commandFailed(lastMessage)

        case .unknown:
            throw PullRequestError.unsupportedHost
        }
    }

    /// The people the picker offers. Never throws: the list is a convenience —
    /// a handle can always be typed in — so a host that will not hand over its
    /// members leaves the picker empty rather than in an error state.
    static func reviewerCandidates(
        for pr: PullRequest,
        in directory: URL
    ) async -> [ReviewerCandidate] {
        let found: [ReviewerCandidate]
        switch pr.host {
        case .github: found = await gitHubCandidates(for: pr, in: directory)
        case .bitbucket: found = await bitbucketCandidates(for: pr, in: directory)
        case .unknown: found = []
        }

        // The sources overlap, so the same person arrives more than once: keep
        // the closest sighting of them, and whatever detail the others had.
        //
        // The author is *not* dropped here, though nobody reviews their own pull
        // request — an `@` in a comment names them more often than anyone, and
        // the reviewer picker is where they are left out of instead.
        var byHandle: [String: ReviewerCandidate] = [:]
        for candidate in found {
            let key = candidate.handle.lowercased()
            guard let existing = byHandle[key] else {
                byHandle[key] = candidate
                continue
            }
            var merged = candidate.relevance < existing.relevance ? candidate : existing
            merged.detail = merged.detail ?? existing.detail ?? candidate.detail
            merged.avatarURL = merged.avatarURL ?? existing.avatarURL ?? candidate.avatarURL
            merged.accountID = merged.accountID ?? existing.accountID ?? candidate.accountID
            byHandle[key] = merged
        }

        return byHandle.values.sorted { lhs, rhs in
            if lhs.relevance != rhs.relevance { return lhs.relevance < rhs.relevance }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    // MARK: - GitHub

    private static func gitHubReviewers(
        for pr: PullRequest,
        in directory: URL
    ) async throws -> [PullRequestReviewer] {
        let result = await GitHubCLI.run(
            ["pr", "view", "\(pr.number)", "--json", "reviewRequests,latestReviews"],
            in: directory,
            timeout: 60
        )
        guard result.isSuccess else {
            throw PullRequestError.commandFailed(result.failureMessage)
        }

        struct Response: Decodable {
            let reviewRequests: [GitHubReviewRequest]?
            let latestReviews: [GitHubReview]?
        }

        guard let response = try? JSONDecoder().decode(
            Response.self,
            from: Data(result.stdout.utf8)
        ) else {
            throw PullRequestError.commandFailed("Could not read gh's list of reviewers.")
        }

        // The author is dropped by the caller, so this one is asked not to.
        return gitHubReviewers(
            requested: response.reviewRequests,
            reviewed: response.latestReviews,
            author: nil,
            host: pr.url?.host
        )
    }

    private static func gitHubCandidates(
        for pr: PullRequest,
        in directory: URL
    ) async -> [ReviewerCandidate] {
        struct User: Decodable {
            let login: String?
            let name: String?
            let avatarURL: String?

            enum CodingKeys: String, CodingKey {
                case login, name
                case avatarURL = "avatar_url"
            }
        }

        // Three lists rather than one, and everything they answer with is kept:
        // the contributors are whoever has actually worked on the repository, so
        // they lead; the collaborators are the right people but reading them
        // needs push access; and the assignable users are that same list under a
        // name GitHub answers for on read-only access.
        let sources: [(relevance: Int, path: String)] = [
            (0, "repos/{owner}/{repo}/contributors"),
            (1, "repos/{owner}/{repo}/collaborators"),
            (2, "repos/{owner}/{repo}/assignees")
        ]
        // Asked all at once: three paginated calls one after another is a wait
        // with a spinner on it, and none of them needs the others' answer.
        let answers: [(relevance: Int, json: String)] = await withTaskGroup(
            of: (Int, String)?.self
        ) { group in
            for source in sources {
                group.addTask {
                    let result = await GitHubCLI.run(
                        ["api", "--paginate", "\(source.path)?per_page=100"],
                        in: directory,
                        timeout: 60
                    )
                    return result.isSuccess ? (source.relevance, result.stdout) : nil
                }
            }
            var collected: [(Int, String)] = []
            for await answer in group {
                if let answer { collected.append(answer) }
            }
            return collected
        }

        return answers.flatMap { answer in
            decodeJSONArrayPages(answer.json, as: User.self).compactMap { user in
                guard let login = user.login, !login.isEmpty else { return nil }
                // The contributors carry the automations along with the people.
                guard !login.hasSuffix("[bot]") else { return nil }
                return ReviewerCandidate(
                    handle: login,
                    name: login,
                    detail: user.name,
                    avatarURL: AvatarURL.hosted(user.avatarURL)
                        ?? AvatarURL.gitHub(login: login, host: pr.url?.host),
                    relevance: answer.relevance
                )
            }
        }
    }

    // MARK: - Bitbucket

    private static func bitbucketReviewers(
        for pr: PullRequest,
        in directory: URL
    ) async throws -> [PullRequestReviewer] {
        // The API first, and asked for the two lists alone: `bkt pr view`
        // fetches the whole pull request — a description of a few thousand
        // characters among it — to be read for the names of three people. It is
        // still underneath, because Data Center has no `/2.0/` to answer.
        if let repository = pr.bitbucketRepository,
           let object = await PullRequestService.bitbucketAPIObject(
               "/2.0/repositories/\(repository)/pullrequests/\(pr.number)",
               params: ["fields=reviewers,participants"],
               in: directory
           ),
           let reviewers = decodeBitbucketReviewers(from: object) {
            return reviewers
        }

        var attempts: [[String]] = []
        let base = ["bkt", "pr", "view", "\(pr.number)", "--json"]
        if !pr.repositoryOwner.isEmpty, !pr.repositorySlug.isEmpty {
            attempts.append(base + ["--workspace", pr.repositoryOwner, "--repo", pr.repositorySlug])
            attempts.append(base + ["--project", pr.repositoryOwner, "--repo", pr.repositorySlug])
        }
        attempts.append(base)

        var lastMessage = "bkt said nothing about who is reviewing #\(pr.number)."
        for command in attempts {
            let result = await Shell.run(command, in: directory, timeout: 60)
            guard result.isSuccess else {
                lastMessage = result.failureMessage
                continue
            }
            guard let object = try? JSONSerialization.jsonObject(with: Data(result.stdout.utf8)),
                  let reviewers = decodeBitbucketReviewers(from: object)
            else {
                lastMessage = "Could not read bkt's JSON output."
                continue
            }
            return reviewers
        }

        throw PullRequestError.commandFailed(lastMessage)
    }

    /// Reads whichever of Bitbucket's two lists the payload carries.
    ///
    /// `reviewers` is who was asked and, on Data Center, what they said;
    /// `participants` is everyone who has touched the pull request and, on
    /// Cloud, what they said. Reading both and letting a verdict win over its
    /// absence covers either flavour. Nil means neither list was there at all,
    /// which is not the same as an empty one — the caller then tries elsewhere.
    static func decodeBitbucketReviewers(from object: Any) -> [PullRequestReviewer]? {
        guard let lists = bitbucketReviewerLists(in: object) else { return nil }

        var reviewers: [PullRequestReviewer] = []
        for item in lists.reviewers + lists.participants {
            let user = (item["user"] as? [String: Any]) ?? item
            guard let name = BitbucketUser.name(from: user) else { continue }

            let approved = item["approved"] as? Bool
            // Data Center calls it `status`, Cloud `state`.
            let raw = (item["status"] as? String) ?? (item["state"] as? String)
            let hasVerdict = approved != nil || raw != nil
            let role = (item["role"] as? String)?.uppercased()
            // Someone who only commented is not a reviewer; someone who
            // approved is one whether the host calls them that or not.
            if !hasVerdict, role == "PARTICIPANT" { continue }

            let state: PullRequestReviewer.State = approved == true ? .approved : .parse(raw)
            let reviewer = PullRequestReviewer(
                handle: bitbucketHandle(for: user, name: name),
                name: name,
                avatarURL: bitbucketAvatar(for: user),
                state: state
            )

            guard let existing = reviewers.firstIndex(where: {
                $0.id.caseInsensitiveCompare(reviewer.id) == .orderedSame
            }) else {
                reviewers.append(reviewer)
                continue
            }
            // The same person from the other list: keep the entry that actually
            // says something, and the face if only one of them had it.
            if hasVerdict { reviewers[existing].state = state }
            if reviewers[existing].avatarURL == nil {
                reviewers[existing].avatarURL = reviewer.avatarURL
            }
        }
        return reviewers
    }

    /// The two lists, wherever the payload keeps them: at the top level, one
    /// level inside a `bkt` wrapper, or in the first item of an array.
    private static func bitbucketReviewerLists(
        in object: Any
    ) -> (reviewers: [[String: Any]], participants: [[String: Any]])? {
        func lists(
            in dictionary: [String: Any]
        ) -> (reviewers: [[String: Any]], participants: [[String: Any]])? {
            let reviewers = dictionary["reviewers"] as? [[String: Any]]
            let participants = dictionary["participants"] as? [[String: Any]]
            guard reviewers != nil || participants != nil else { return nil }
            return (reviewers ?? [], participants ?? [])
        }

        if let array = object as? [[String: Any]], let first = array.first {
            return lists(in: first)
        }
        guard let dictionary = object as? [String: Any] else { return nil }
        if let found = lists(in: dictionary) { return found }
        for value in dictionary.values {
            if let nested = value as? [String: Any], let found = lists(in: nested) {
                return found
            }
            if let array = value as? [[String: Any]],
               let first = array.first,
               let found = lists(in: first) {
                return found
            }
        }
        return nil
    }

    /// Everyone Bitbucket will name for this repository.
    ///
    /// There is no one list to ask for, and the obvious one is not always
    /// allowed: Cloud's members endpoint answers 403 unless the token carries the
    /// `account` scope. So the people are gathered from everywhere they turn up —
    /// the repository's **default reviewers**, the authors of its **recent
    /// commits**, whoever **opened or merged its recent pull requests**, the
    /// **workspace's members**, and on Data Center the repository's own users and
    /// the instance's user directory.
    ///
    /// All of them are asked at once and everything they say is kept: they
    /// overlap, one flavour's endpoints 404 on the other, and a workspace of
    /// eighty people is worth having as long as the handful who review *this*
    /// repository come first — which is what `relevance` is for.
    private static func bitbucketCandidates(
        for pr: PullRequest,
        in directory: URL
    ) async -> [ReviewerCandidate] {
        guard !pr.repositoryOwner.isEmpty else { return [] }

        var sources: [(relevance: Int, command: [String])] = []
        if !pr.repositorySlug.isEmpty {
            let repository = "\(pr.repositoryOwner)/\(pr.repositorySlug)"
            sources.append((0, ["bkt", "api", "/2.0/repositories/\(repository)/default-reviewers",
                                "--param", "pagelen=100"]))
            sources.append((0, ["bkt", "api", "/2.0/repositories/\(repository)/commits",
                                "--param", "pagelen=50"]))
            sources.append((1, ["bkt", "api", "/2.0/repositories/\(repository)/pullrequests",
                                "--param", "state=MERGED", "--param", "pagelen=25"]))
            sources.append((1, ["bkt", "api",
                                "/rest/api/1.0/projects/\(pr.repositoryOwner)/repos/\(pr.repositorySlug)/permissions/users",
                                "--param", "limit=100"]))
        }
        sources.append((2, ["bkt", "api", "/2.0/workspaces/\(pr.repositoryOwner)/members",
                            "--param", "pagelen=100"]))
        sources.append((3, ["bkt", "api", "/rest/api/1.0/users", "--param", "limit=100"]))

        let answers: [(relevance: Int, json: String)] = await withTaskGroup(
            of: (Int, String)?.self
        ) { group in
            for source in sources {
                group.addTask {
                    let result = await Shell.run(source.command, in: directory, timeout: 60)
                    return result.isSuccess ? (source.relevance, result.stdout) : nil
                }
            }
            var collected: [(Int, String)] = []
            for await answer in group {
                if let answer { collected.append(answer) }
            }
            return collected
        }

        return answers.flatMap { answer in
            bitbucketUsers(in: answer.json).compactMap {
                bitbucketCandidate(from: $0, relevance: answer.relevance)
            }
        }
    }

    private static func bitbucketCandidate(
        from user: [String: Any],
        relevance: Int = 0
    ) -> ReviewerCandidate? {
        guard let name = BitbucketUser.name(from: user) else { return nil }
        let display = (user["display_name"] as? String) ?? (user["displayName"] as? String)
        return ReviewerCandidate(
            handle: bitbucketHandle(for: user, name: name),
            name: name,
            detail: display == name ? nil : display,
            avatarURL: bitbucketAvatar(for: user),
            accountID: user["account_id"] as? String,
            relevance: relevance
        )
    }

    /// Every person anywhere in a Bitbucket payload.
    ///
    /// The endpoints above each keep their people somewhere else — the default
    /// reviewers *are* the list, a commit hangs its author off `author.user`, a
    /// pull request off `author` and `closed_by`, the members list off
    /// `values[].user` — so rather than a reader per endpoint this walks whatever
    /// came back and keeps what looks like a person. Cloud says so outright
    /// (`"type": "user"`); a Data Center user carries a slug, a name and a
    /// display name, and calls itself NORMAL or SERVICE.
    private static func bitbucketUsers(in json: String) -> [[String: Any]] {
        guard let root = try? JSONSerialization.jsonObject(with: Data(json.utf8)) else {
            return []
        }

        func isUser(_ dictionary: [String: Any]) -> Bool {
            let type = (dictionary["type"] as? String)?.uppercased()
            if type == "USER" { return true }
            // Bitbucket's own automations are not people to ask.
            if type == "SERVICE" { return false }
            return dictionary["slug"] is String
                && dictionary["name"] is String
                && (dictionary["displayName"] is String || dictionary["emailAddress"] is String)
        }

        var found: [[String: Any]] = []
        func walk(_ value: Any) {
            if let dictionary = value as? [String: Any] {
                if isUser(dictionary) { found.append(dictionary) }
                // Kept walking either way: a user object holds nothing but
                // itself, and everything else holds users somewhere inside.
                for nested in dictionary.values { walk(nested) }
                return
            }
            if let array = value as? [Any] {
                for element in array { walk(element) }
            }
        }
        walk(root)
        return found
    }

    /// What `--reviewer` takes for this person. Cloud usernames are on their way
    /// out and its payloads carry a `{uuid}` instead, which `bkt` accepts as it
    /// stands; Data Center has no uuid and takes the username itself.
    private static func bitbucketHandle(for user: [String: Any], name: String) -> String {
        if let uuid = user["uuid"] as? String, !uuid.isEmpty { return uuid }
        return BitbucketUser.login(from: user) ?? name
    }

    private static func bitbucketAvatar(for user: [String: Any]) -> URL? {
        let hosted = ((user["links"] as? [String: Any])?["avatar"] as? [String: Any])?["href"]
        return AvatarURL.hosted(hosted as? String)
            ?? AvatarURL.hosted(user["avatarUrl"] as? String)
    }
}
