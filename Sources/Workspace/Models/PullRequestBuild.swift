import Foundation

/// One CI run attached to a pull request, normalised across hosts.
///
/// GitHub calls these checks, Bitbucket Data Center build statuses and
/// Bitbucket Cloud pipelines. They are the same thing to a reviewer: a named
/// job, how it ended, and a page on the host with the log.
struct PullRequestBuild: Identifiable, Sendable, Hashable {
    enum State: String, Sendable {
        case passed, failed, running, pending, cancelled, skipped, unknown

        var title: String {
            switch self {
            case .passed: "Passed"
            case .failed: "Failed"
            case .running: "Running"
            case .pending: "Pending"
            case .cancelled: "Cancelled"
            case .skipped: "Skipped"
            case .unknown: "Unknown"
            }
        }

        var symbol: String {
            switch self {
            case .passed: "checkmark.circle.fill"
            case .failed: "xmark.octagon.fill"
            case .running: "circle.dotted"
            case .pending: "clock"
            case .cancelled: "slash.circle"
            case .skipped: "minus.circle"
            case .unknown: "questionmark.circle"
            }
        }

        /// Every host spells these differently, and one host spells them
        /// differently in two places — Cloud reports a pipeline's outcome in
        /// `state.result.name` but a commit status's in `state`. Matching on
        /// what the word contains covers all of them without a table per host.
        static func parse(_ raw: String?) -> State {
            guard let raw = raw?.lowercased(), !raw.isEmpty else { return .unknown }
            if raw.contains("success") || raw.contains("pass") { return .passed }
            if raw.contains("fail") || raw.contains("error") || raw.contains("timed_out") {
                return .failed
            }
            if raw.contains("progress") || raw.contains("running") || raw.contains("build") {
                return .running
            }
            if raw.contains("cancel") || raw.contains("stop") || raw.contains("abort") {
                return .cancelled
            }
            if raw.contains("skip") || raw.contains("neutral") || raw.contains("stale") {
                return .skipped
            }
            if raw.contains("pend") || raw.contains("queue") || raw.contains("expect")
                || raw.contains("wait") {
                return .pending
            }
            return .unknown
        }
    }

    var id: String
    /// The job's own name — "build (macOS)", "Pipeline #482".
    var name: String
    /// What produced it, when the host says: the workflow on GitHub, the
    /// status's description on Bitbucket. Nil when there is nothing to add.
    var detail: String?
    var state: State
    var startedAt: Date?
    var finishedAt: Date?
    var url: URL?

    /// How long it ran, once it has stopped. Nil while it is still going, which
    /// is when an elapsed time would be stale the moment it is drawn.
    var duration: TimeInterval? {
        guard let startedAt, let finishedAt, finishedAt > startedAt else { return nil }
        return finishedAt.timeIntervalSince(startedAt)
    }

    /// `2m 14s`, or `18s` under a minute.
    var durationLabel: String? {
        guard let duration else { return nil }
        let total = Int(duration.rounded())
        let minutes = total / 60
        let seconds = total % 60
        return minutes > 0 ? "\(minutes)m \(seconds)s" : "\(seconds)s"
    }
}

extension PullRequestService {
    /// The CI runs for a pull request, worst news first: a reviewer opens this
    /// tab because something failed, and a long green list should not bury it.
    static func builds(for pr: PullRequest, in directory: URL) async throws -> [PullRequestBuild] {
        let builds = switch pr.host {
        case .github: try await gitHubBuilds(for: pr, in: directory)
        case .bitbucket: try await bitbucketBuilds(for: pr, in: directory)
        case .unknown: throw PullRequestError.unsupportedHost
        }
        return builds.sorted { lhs, rhs in
            let left = sortRank(lhs.state)
            let right = sortRank(rhs.state)
            if left != right { return left < right }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private static func sortRank(_ state: PullRequestBuild.State) -> Int {
        switch state {
        case .failed: 0
        case .running: 1
        case .pending: 2
        case .cancelled: 3
        case .unknown: 4
        case .passed: 5
        case .skipped: 6
        }
    }

    // MARK: - GitHub

    private static func gitHubBuilds(
        for pr: PullRequest,
        in directory: URL
    ) async throws -> [PullRequestBuild] {
        let result = await GitHubCLI.run(
            ["pr", "checks", "\(pr.number)", "--json",
             "name,state,bucket,link,startedAt,completedAt,workflow,description"],
            in: directory,
            timeout: 60
        )

        // `gh pr checks` reports the checks themselves through its exit code —
        // 8 while any is pending, 1 when one has failed. Both still print the
        // list, so the JSON decides whether this worked, not the status.
        struct Check: Decodable {
            let name: String?
            let state: String?
            let bucket: String?
            let link: String?
            let startedAt: String?
            let completedAt: String?
            let workflow: String?
            let description: String?
        }

        guard let checks = try? JSONDecoder().decode([Check].self, from: Data(result.stdout.utf8)) else {
            // No checks at all is not a failure: gh says so on stderr and
            // prints nothing, and the tab has its own empty state for it.
            if result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               result.failureMessage.lowercased().contains("no checks") {
                return []
            }
            throw PullRequestError.commandFailed(
                result.isSuccess ? "Could not read gh's list of checks." : result.failureMessage
            )
        }

        return checks.enumerated().map { index, check in
            let name = check.name?.isEmpty == false ? check.name! : "Check \(index + 1)"
            let workflow = check.workflow?.isEmpty == false ? check.workflow : nil
            let description = check.description?.isEmpty == false ? check.description : nil
            return PullRequestBuild(
                id: "\(index)-\(name)",
                name: name,
                // The workflow says where the job comes from, which is what
                // tells two identically named jobs apart.
                detail: workflow ?? description,
                // `bucket` is gh's own summary of `state`; it is the coarser of
                // the two and the one that maps cleanly onto our states.
                state: .parse(check.bucket ?? check.state),
                startedAt: check.startedAt.flatMap(parseTimestamp),
                finishedAt: check.completedAt.flatMap(parseTimestamp),
                url: check.link.flatMap(URL.init(string:))
            )
        }
    }

    // MARK: - Bitbucket

    /// The pull request's own build statuses, and only if that fails, the older
    /// roundabout ways to the same answer.
    ///
    /// Cloud has an endpoint for exactly this question —
    /// `/pullrequests/{id}/statuses` — and it is one call: no `bkt status pr`
    /// first, no head commit to resolve before the commit's statuses can be
    /// asked for (which cost a **commit listing** of its own), no repository
    /// pipeline list to filter down by branch afterwards. Four calls became
    /// one, and the three below are what Data Center still needs.
    private static func bitbucketBuilds(
        for pr: PullRequest,
        in directory: URL
    ) async throws -> [PullRequestBuild] {
        if let repository = pr.bitbucketRepository,
           let json = await PullRequestService.bitbucketAPI(
               "/2.0/repositories/\(repository)/pullrequests/\(pr.number)/statuses",
               params: ["pagelen=50"],
               in: directory
           ) {
            let builds = decodeBitbucketStatuses(json, pr: pr)
            if !builds.isEmpty { return builds }
        }

        let statuses = await Shell.run(
            ["bkt", "status", "pr", "\(pr.number)", "--json"],
            in: directory,
            timeout: 60
        )
        if statuses.isSuccess {
            let builds = decodeBitbucketStatuses(statuses.stdout, pr: pr)
            if !builds.isEmpty { return builds }
        }

        if let repository = pr.bitbucketRepository,
           let sha = await bitbucketHeadSHA(for: pr, in: directory),
           let json = await PullRequestService.bitbucketAPI(
               "/2.0/repositories/\(repository)/commit/\(sha)/statuses",
               params: ["pagelen=50"],
               in: directory
           ) {
            let builds = decodeBitbucketStatuses(json, pr: pr)
            if !builds.isEmpty { return builds }
        }

        // Last: a pipeline that never posted a status of its own is still
        // listed under the branch it ran on.
        if let repository = pr.bitbucketRepository,
           let json = await PullRequestService.bitbucketAPI(
               "/2.0/repositories/\(repository)/pipelines",
               params: ["sort=-created_on", "pagelen=20"],
               in: directory
           ) {
            return decodeBitbucketPipelines(json, pr: pr)
        }

        let pipelines = await Shell.run(
            ["bkt", "pipeline", "list", "--limit", "20", "--json"],
            in: directory,
            timeout: 60
        )
        if pipelines.isSuccess {
            return decodeBitbucketPipelines(pipelines.stdout, pr: pr)
        }
        return []
    }

    /// The commit the pull request's builds are attached to. GitHub fills this
    /// in when the pull request is listed; Bitbucket does not, so it costs a
    /// commit listing — the newest one is the head.
    private static func bitbucketHeadSHA(for pr: PullRequest, in directory: URL) async -> String? {
        if !pr.headSHA.isEmpty { return pr.headSHA }
        let commits = try? await commits(for: pr, in: directory)
        return commits?.first?.sha
    }

    /// Data Center answers `{ "statuses": [...] }` or a bare array, Cloud
    /// `{ "values": [...] }`, and `bkt status pr` wraps either in a payload of
    /// its own. Take the first array of objects any of them offers.
    private static func decodeBitbucketStatuses(
        _ json: String,
        pr: PullRequest
    ) -> [PullRequestBuild] {
        guard let values = firstArray(in: json, keys: ["statuses", "values", "results", "builds"])
        else { return [] }

        return values.enumerated().compactMap { index, item in
            let key = item["key"] as? String
            let name = (item["name"] as? String)
                ?? key
                ?? (item["description"] as? String)
                ?? "Build \(index + 1)"
            let description = item["description"] as? String
            // Cloud sends an ISO timestamp, Data Center epoch milliseconds.
            let created = (item["created_on"] as? String)
                ?? (item["dateAdded"] as? Int).map { "\($0)" }
                ?? (item["createdDate"] as? Int).map { "\($0)" }
            let updated = (item["updated_on"] as? String)
                ?? (item["dateUpdated"] as? Int).map { "\($0)" }

            return PullRequestBuild(
                id: key ?? "\(index)-\(name)",
                name: name,
                detail: description == name ? nil : description,
                state: .parse(item["state"] as? String),
                startedAt: created.flatMap(parseTimestamp),
                finishedAt: updated.flatMap(parseTimestamp),
                url: (item["url"] as? String).flatMap(URL.init(string:))
            )
        }
    }

    /// A Cloud pipeline run, kept only when it belongs to this pull request's
    /// branch — the list is the repository's, not the pull request's.
    private static func decodeBitbucketPipelines(
        _ json: String,
        pr: PullRequest
    ) -> [PullRequestBuild] {
        guard let values = firstArray(in: json, keys: ["values", "pipelines", "results"])
        else { return [] }

        return values.compactMap { item in
            let target = item["target"] as? [String: Any]
            let branch = (target?["ref_name"] as? String)
                ?? (target?["branch"] as? String)
                ?? (item["branch"] as? String)
            guard branch == pr.sourceBranch else { return nil }

            let number = (item["build_number"] as? Int).map { "#\($0)" }
                ?? (item["buildNumber"] as? Int).map { "#\($0)" }
                ?? ""
            let state = item["state"] as? [String: Any]
            // A finished pipeline reports how it finished one level down; a
            // running one has no result yet and its own name is the answer.
            let result = (state?["result"] as? [String: Any])?["name"] as? String
                ?? (state?["name"] as? String)
                ?? (item["result"] as? String)
                ?? (item["state"] as? String)

            return PullRequestBuild(
                id: (item["uuid"] as? String) ?? number,
                name: number.isEmpty ? "Pipeline" : "Pipeline \(number)",
                detail: (target?["selector"] as? [String: Any])?["pattern"] as? String,
                state: .parse(result),
                startedAt: (item["created_on"] as? String).flatMap(parseTimestamp),
                finishedAt: (item["completed_on"] as? String).flatMap(parseTimestamp),
                url: pipelineURL(for: pr, number: item["build_number"] as? Int)
            )
        }
    }

    /// Cloud's pipeline pages hang off the repository, which the pull request's
    /// own URL is two components above.
    private static func pipelineURL(for pr: PullRequest, number: Int?) -> URL? {
        guard let number, let url = pr.url else { return nil }
        return url
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("pipelines")
            .appendingPathComponent("results")
            .appendingPathComponent("\(number)")
    }

    /// The first array of objects to be found: at the top level, under one of
    /// `keys`, or under one of `keys` nested one level in. Every Bitbucket
    /// flavour and every `bkt` wrapper puts the list in one of those places.
    private static func firstArray(in json: String, keys: [String]) -> [[String: Any]]? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) else {
            return nil
        }
        if let array = object as? [[String: Any]] { return array }
        guard let dictionary = object as? [String: Any] else { return nil }
        for key in keys {
            if let array = dictionary[key] as? [[String: Any]] { return array }
        }
        for value in dictionary.values {
            guard let nested = value as? [String: Any] else { continue }
            for key in keys {
                if let array = nested[key] as? [[String: Any]] { return array }
            }
        }
        return nil
    }
}
