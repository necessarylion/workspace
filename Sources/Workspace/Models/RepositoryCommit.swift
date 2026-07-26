import Foundation

/// One commit in the repository's own history, read from `git log`.
///
/// Separate from `PullRequestCommit`: that one comes from a host and belongs to
/// a pull request, this one is what the local checkout has on the branch that is
/// out right now. The dashboard shows these.
struct RepositoryCommit: Identifiable, Sendable, Hashable {
    var sha: String
    /// The first line of the message.
    var headline: String
    /// Everything after it, already trimmed.
    var body: String
    var author: String
    var date: Date?

    var id: String { sha }
    var shortSHA: String { String(sha.prefix(7)) }

    /// How many the dashboard reads at once, and how many more each “Load older
    /// commits” adds. Deep enough to cover a busy week, short enough that
    /// `git log` stays instant.
    static let pageSize = 40

    /// What one read of the history came back with: the commits themselves, and
    /// whether git had older ones behind them — which is what tells the
    /// dashboard whether there is anything left to load.
    struct Page: Sendable {
        var commits: [RepositoryCommit] = []
        var hasMore = false
    }

    // MARK: - Reading

    /// The newest commits on whatever is checked out, newest first. Empty when
    /// the folder is not a repository, or has no commit yet.
    ///
    /// It asks git for one commit more than it wants: if that extra one comes
    /// back, there is older history to load, and it is dropped before returning.
    static func load(in directory: URL, limit: Int = pageSize) async -> Page {
        // Unit separators keep the fields apart, and a record separator keeps
        // the commits apart — a message body has newlines of its own, so a line
        // is not a safe boundary.
        let result = await Shell.run(
            ["git", "log", "-n", "\(limit + 1)", "--format=%H%x1f%an%x1f%aI%x1f%s%x1f%b%x1e"],
            in: directory,
            timeout: 30
        )
        guard result.isSuccess else { return Page() }

        let formatter = ISO8601DateFormatter()
        let commits = result.stdout
            .split(separator: "\u{1e}", omittingEmptySubsequences: true)
            .compactMap { record -> RepositoryCommit? in
                let fields = record
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .components(separatedBy: "\u{1f}")
                guard fields.count == 5, !fields[0].isEmpty else { return nil }
                return RepositoryCommit(
                    sha: fields[0],
                    headline: fields[3],
                    body: fields[4].trimmingCharacters(in: .whitespacesAndNewlines),
                    author: fields[1],
                    date: formatter.date(from: fields[2])
                )
            }
        return Page(commits: Array(commits.prefix(limit)), hasMore: commits.count > limit)
    }

    /// The patch this commit introduced. Merges show nothing on their own, so
    /// `--first-parent` gives them the diff against the branch they landed on
    /// rather than an empty answer.
    static func diff(sha: String, in directory: URL) async -> String {
        let result = await Shell.run(
            ["git", "show", "--format=", "--patch", "--first-parent", "--no-color", sha],
            in: directory,
            timeout: 60
        )
        return result.isSuccess ? result.stdout : ""
    }
}

// MARK: - Grouping

/// A day's worth of commits, as the dashboard lists them.
struct CommitDay: Identifiable {
    /// Midnight of the day, or nil for commits git gave no readable date for.
    var date: Date?
    var commits: [RepositoryCommit]

    /// The first commit's hash identifies the group: a date cannot, since a
    /// commit git gave no readable date for lands in a group without one.
    var id: String { commits.first?.sha ?? "empty" }

    /// "Today", "Yesterday", or the date written out — the year only when it is
    /// not this one.
    var title: String {
        guard let date else { return "Earlier" }
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        if calendar.isDate(date, equalTo: Date(), toGranularity: .year) {
            return date.formatted(.dateTime.weekday(.abbreviated).day().month(.wide))
        }
        return date.formatted(.dateTime.day().month(.wide).year())
    }

    /// Buckets commits by the day they were authored, keeping the newest-first
    /// order `git log` already put them in.
    static func group(_ commits: [RepositoryCommit]) -> [CommitDay] {
        let calendar = Calendar.current
        var days: [CommitDay] = []
        for commit in commits {
            let day = commit.date.map { calendar.startOfDay(for: $0) }
            if !days.isEmpty, days.last?.date == day {
                days[days.count - 1].commits.append(commit)
            } else {
                days.append(CommitDay(date: day, commits: [commit]))
            }
        }
        return days
    }
}
