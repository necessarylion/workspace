import Foundation

/// What ⌘P lists: the paths of one repository, ranked for what has been typed.
///
/// The ranking is ``ClaudeCompletions/rank(_:in:limit:)`` — the same order the
/// chat's `@` menu offers files in, because it is the same question asked twice
/// and two different answers to it would be a bug you could feel. What is added
/// here is *where* the query landed in each path, so the row can pick those
/// letters out; the chat's one-line menu has no room to show that.
enum FileFinder {
    /// One row of the palette.
    struct Match: Identifiable, Sendable {
        /// Repository-relative, "/"-separated.
        let path: String
        /// Character offsets into `path` that the query matched, ascending.
        /// Empty for a row nothing was typed for — the recent files.
        let highlighted: [Int]

        var id: String { path }

        /// Where the file name starts. The row draws the name and the folders
        /// above it differently, and the highlight has to be split the same way.
        var nameStart: Int {
            guard let slash = path.lastIndex(of: "/") else { return 0 }
            return path.distance(from: path.startIndex, to: slash) + 1
        }

        var name: String {
            String(path.suffix(path.count - nameStart))
        }

        /// The folders above the file, without the trailing slash. Empty for a
        /// file at the root of the repository.
        var folder: String {
            nameStart == 0 ? "" : String(path.prefix(nameStart - 1))
        }
    }

    /// Ranked matches for `query`, off the main actor.
    ///
    /// Detached because a large repository is tens of thousands of paths and
    /// this runs on every keystroke — on the main actor it would be felt in the
    /// field you are typing into.
    static func search(_ query: String, in paths: [String], limit: Int = 100) async -> [Match] {
        await Task.detached(priority: .userInitiated) {
            ClaudeCompletions.rank(query, in: paths, limit: limit).map {
                Match(path: $0, highlighted: highlights(of: query, in: $0))
            }
        }.value
    }

    /// Which characters of `path` the query matched.
    ///
    /// Asked in the order `rank` scores in, so the letters picked out are the
    /// ones the row was ranked for: the run inside the file name first, then a
    /// run anywhere in the path, and only then the scattered letters of a
    /// subsequence — `csv` finding `CodeServiceView`.
    static func highlights(of query: String, in path: String) -> [Int] {
        // Lowercased character by character rather than with `lowercased()` on
        // the whole string: a handful of characters grow a letter when they are
        // lowered, which would shift every offset after them off the character
        // they belong to.
        let needle = folded(query)
        let haystack = folded(path)
        guard !needle.isEmpty, needle.count <= haystack.count else { return [] }

        let nameStart = (haystack.lastIndex(of: "/").map { $0 + 1 }) ?? 0
        if let start = run(of: needle, in: haystack, from: nameStart) {
            return Array(start..<(start + needle.count))
        }
        if let start = run(of: needle, in: haystack, from: 0) {
            return Array(start..<(start + needle.count))
        }
        return subsequence(of: needle, in: haystack, from: nameStart)
            ?? subsequence(of: needle, in: haystack, from: 0)
            ?? []
    }

    /// Lowercased, one character in and one character out.
    private static func folded(_ text: String) -> [Character] {
        text.map { $0.lowercased().first ?? $0 }
    }

    /// Where `needle` sits in `haystack` whole, searching from `start`.
    private static func run(of needle: [Character], in haystack: [Character], from start: Int) -> Int? {
        guard start + needle.count <= haystack.count else { return nil }
        for offset in start...(haystack.count - needle.count) {
            var matched = true
            for index in needle.indices where haystack[offset + index] != needle[index] {
                matched = false
                break
            }
            if matched { return offset }
        }
        return nil
    }

    /// The letters in order but not together, taken as early as they come.
    private static func subsequence(
        of needle: [Character],
        in haystack: [Character],
        from start: Int
    ) -> [Int]? {
        var found: [Int] = []
        found.reserveCapacity(needle.count)
        var next = 0
        for offset in start..<haystack.count where haystack[offset] == needle[next] {
            found.append(offset)
            next += 1
            if next == needle.count { return found }
        }
        return nil
    }
}
