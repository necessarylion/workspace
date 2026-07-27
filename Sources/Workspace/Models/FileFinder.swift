import Foundation

/// What ⌘P lists: the paths of one repository, ranked for what has been typed.
///
/// Both sides are **folded** before anything is compared — lowercased, with
/// every separator dropped — so `item controller`, `item_controller`,
/// `ItemController` and `itemcontroller` are one and the same query, and each of
/// them finds `app/controllers/item_controller.rb`. Nobody remembers whether the
/// file they are after spelled a word break as an underscore, a dash or a
/// capital, and having to get it right is the difference between a palette you
/// reach for and one you fight.
///
/// A file whose *name* starts with what you typed comes before one that merely
/// has those letters in a folder somewhere, and the letters found scattered —
/// `csv` finding `CodeServiceView` — come last of all.
enum FileFinder {
    // MARK: - What a row is

    /// One file in the palette.
    struct Match: Identifiable, Sendable {
        /// Repository-relative, "/"-separated.
        let path: String
        /// Character offsets into `path` that the query matched, ascending.
        /// Empty for a row nothing was typed for — the recent files.
        let highlighted: [Int]

        var id: String { path }

        /// Where the file name starts. The row draws the name and the folders
        /// above it differently, and the highlight is split the same way.
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

    // MARK: - Reading the repository

    /// Every file in the repository, as paths relative to it.
    ///
    /// `git ls-files` rather than walking the folder: it is one call however
    /// deep the tree is, and it already leaves out what `.gitignore` covers —
    /// listing `node_modules/…` would bury the files actually worked on. A
    /// folder that is not a repository falls back to a walk.
    static func paths(in project: URL) async -> [String] {
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
            // A tree with a hundred thousand files is not one anybody picks a
            // file out of, and the list has to stay cheap to filter.
            if paths.count >= 20_000 { break }
        }
        return paths
    }

    // MARK: - The repository, prepared

    /// A repository's paths with their folded forms beside them.
    ///
    /// Folding is a pass over the whole list, so it happens once when the list
    /// is read rather than again on every keystroke. Folded to bytes rather than
    /// to characters because this is the part that is measured in tens of
    /// thousands: a `Character` costs sixteen bytes and a repository's worth of
    /// them is memory spent on nothing a comparison can feel.
    struct Index: Sendable {
        let paths: [String]
        /// Same order as `paths`.
        fileprivate let folded: [[UInt8]]
        /// Where each path's file name starts inside its folded form.
        fileprivate let nameStart: [Int]
        /// How long each path is. Kept because the ordering asks for it once per
        /// comparison and `String.count` walks the whole string to answer —
        /// which a broad query would pay for thousands of times over.
        fileprivate let lengths: [Int]

        var count: Int { paths.count }

        static let empty = Index(paths: [], folded: [], nameStart: [], lengths: [])
    }

    static func index(_ paths: [String]) async -> Index {
        await Task.detached(priority: .userInitiated) {
            var folded: [[UInt8]] = []
            var starts: [Int] = []
            var lengths: [Int] = []
            folded.reserveCapacity(paths.count)
            starts.reserveCapacity(paths.count)
            lengths.reserveCapacity(paths.count)

            for path in paths {
                let one = fold(path)
                folded.append(one.bytes)
                starts.append(one.nameStart)
                lengths.append(path.utf8.count)
            }
            return Index(paths: paths, folded: folded, nameStart: starts, lengths: lengths)
        }.value
    }

    // MARK: - Searching

    /// The rows worth showing for `query`, best first.
    ///
    /// Detached because a large repository is tens of thousands of paths and
    /// this runs on every keystroke — on the main actor it would be felt in the
    /// field being typed into.
    static func search(_ query: String, in index: Index, limit: Int = 100) async -> [Match] {
        await Task.detached(priority: .userInitiated) {
            let needle = fold(query).bytes
            guard !needle.isEmpty else { return [] }

            // Only the best `limit` rows are ever shown, so only those are kept
            // as we go. Collecting every match and sorting the lot was by far
            // the slowest thing here: a query of one letter matches nearly every
            // path in the repository, and all but a hundred of them were sorted
            // into their exact place only to be thrown away.
            var best: [Candidate] = []
            best.reserveCapacity(limit + 1)

            for row in index.paths.indices {
                // A search nobody is waiting for any more should not go on
                // burning a core: the next keystroke cancelled this one.
                if row & 0x3ff == 0, Task.isCancelled { return [] }

                guard let rank = rank(
                    index.folded[row],
                    nameStart: index.nameStart[row],
                    against: needle
                ) else { continue }

                let candidate = Candidate(row: row, rank: rank, length: index.lengths[row])
                // Once the list is full, all but the good ones are settled by a
                // single comparison against the row about to fall off the end.
                if best.count == limit, !candidate.beats(best[limit - 1]) { continue }
                best.insert(candidate, at: place(of: candidate, in: best))
                if best.count > limit { best.removeLast() }
            }

            return best.map { candidate in
                let path = index.paths[candidate.row]
                return Match(path: path, highlighted: highlights(of: query, in: path))
            }
        }.value
    }

    /// One row still in the running, and what it is ordered by.
    private struct Candidate {
        let row: Int
        let rank: Int
        let length: Int

        /// Best first: where the match landed, then the shortest path — of two
        /// files matching equally well, the one nearer the root is nearly always
        /// the one being looked for — and finally the order the list came in,
        /// which is the alphabetical one `git ls-files` prints.
        func beats(_ other: Candidate) -> Bool {
            if rank != other.rank { return rank < other.rank }
            if length != other.length { return length < other.length }
            return row < other.row
        }
    }

    /// Where `candidate` belongs in a list that is already in order.
    private static func place(of candidate: Candidate, in best: [Candidate]) -> Int {
        var low = 0
        var high = best.count
        while low < high {
            let middle = (low + high) / 2
            if candidate.beats(best[middle]) {
                high = middle
            } else {
                low = middle + 1
            }
        }
        return low
    }

    /// How well one path answers the query — lower is better, `nil` is no match.
    ///
    /// Where the match lands is what is being ranked, not how much of it there
    /// is: what you nearly always want is the file whose name begins with what
    /// you typed, and it should not be sitting under twenty files that happen to
    /// carry those letters in a folder name.
    private static func rank(_ folded: [UInt8], nameStart: Int, against needle: [UInt8]) -> Int? {
        let name = folded[nameStart...]
        let whole = folded[...]

        if name.count == needle.count, name.elementsEqual(needle) { return 0 }
        if starts(name, with: needle) { return 1 }
        if starts(whole, with: needle) { return 2 }
        if holds(name, needle) { return 3 }
        if holds(whole, needle) { return 4 }
        if isSubsequence(needle, of: name) { return 5 }
        if isSubsequence(needle, of: whole) { return 6 }
        return nil
    }

    private static func starts(_ haystack: ArraySlice<UInt8>, with needle: [UInt8]) -> Bool {
        needle.count <= haystack.count && haystack.prefix(needle.count).elementsEqual(needle)
    }

    /// `needle` somewhere inside `haystack`, whole.
    private static func holds(_ haystack: ArraySlice<UInt8>, _ needle: [UInt8]) -> Bool {
        guard needle.count <= haystack.count else { return false }
        for start in haystack.startIndex...(haystack.endIndex - needle.count)
        where haystack[start..<(start + needle.count)].elementsEqual(needle) {
            return true
        }
        return false
    }

    /// The letters in order but not together.
    private static func isSubsequence(_ needle: [UInt8], of haystack: ArraySlice<UInt8>) -> Bool {
        var next = 0
        for byte in haystack where byte == needle[next] {
            next += 1
            if next == needle.count { return true }
        }
        return false
    }

    // MARK: - Folding

    /// What a query is allowed to leave out. The punctuation of a path is what
    /// you remember least about it, so none of it has to be typed — and a space
    /// stands in for all of it, which is how `item controller` finds
    /// `item_controller`.
    private static let separators: Set<Character> = [" ", "\t", "_", "-", ".", "/"]

    private static func isSeparator(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: " "), UInt8(ascii: "\t"), UInt8(ascii: "_"),
             UInt8(ascii: "-"), UInt8(ascii: "."), UInt8(ascii: "/"):
            true
        default:
            false
        }
    }

    /// Lowercased ASCII with the separators dropped, and where the file name
    /// begins in what is left. Bytes above ASCII are carried through untouched:
    /// they have no case to fold and no separator among them.
    private static func fold(_ text: String) -> (bytes: [UInt8], nameStart: Int) {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(text.utf8.count)
        var nameStart = 0

        for byte in text.utf8 {
            // The last slash is what divides the folders from the name, and it
            // is dropped like every other separator — so the name starts at
            // whatever has been folded so far.
            if byte == UInt8(ascii: "/") {
                nameStart = bytes.count
                continue
            }
            guard !isSeparator(byte) else { continue }
            bytes.append(byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z") ? byte + 32 : byte)
        }
        return (bytes, nameStart)
    }

    // MARK: - Where the query landed

    /// Which characters of `path` the query matched, so the row can pick them
    /// out. Asked of the winners alone — a hundred rows, not a repository — and
    /// so it can afford to work in characters, which is what the offsets it
    /// returns have to index.
    ///
    /// Empty when the folded forms matched in a way this cannot retrace, which
    /// costs the row its highlight and nothing else.
    static func highlights(of query: String, in path: String) -> [Int] {
        let needle = unfolded(query).folded
        let (folded, origin, nameStart) = unfolded(path)
        guard !needle.isEmpty, needle.count <= folded.count else { return [] }

        guard let matched = run(of: needle, in: folded, from: nameStart)
            ?? run(of: needle, in: folded, from: 0)
            ?? scattered(needle, in: folded, from: nameStart)
            ?? scattered(needle, in: folded, from: 0)
        else { return [] }

        return offsets(of: matched, in: origin)
    }

    /// The same fold as `fold`, in characters, keeping where each one came from.
    private static func unfolded(_ text: String) -> (folded: [Character], origin: [Int], nameStart: Int) {
        var folded: [Character] = []
        var origin: [Int] = []
        var nameStart = 0

        for (offset, character) in text.enumerated() {
            if character == "/" {
                nameStart = folded.count
                continue
            }
            guard !separators.contains(character) else { continue }
            folded.append(character.lowercased().first ?? character)
            origin.append(offset)
        }
        return (folded, origin, nameStart)
    }

    /// The folded positions of `needle` sitting in `haystack` whole.
    private static func run(of needle: [Character], in haystack: [Character], from start: Int) -> [Int]? {
        guard start + needle.count <= haystack.count else { return nil }
        for offset in start...(haystack.count - needle.count) {
            var matched = true
            for index in needle.indices where haystack[offset + index] != needle[index] {
                matched = false
                break
            }
            if matched { return Array(offset..<(offset + needle.count)) }
        }
        return nil
    }

    /// The folded positions of `needle` found letter by letter, taken as early
    /// as they come.
    private static func scattered(_ needle: [Character], in haystack: [Character], from start: Int) -> [Int]? {
        guard start < haystack.count else { return nil }
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

    /// Folded positions back into offsets in the path itself.
    ///
    /// A separator sitting between two letters that the fold made neighbours is
    /// taken along: the `_` of `item_controller` is inside what the query
    /// matched, and leaving it plain would break the highlight in two.
    private static func offsets(of matched: [Int], in origin: [Int]) -> [Int] {
        var result: [Int] = []
        result.reserveCapacity(matched.count)

        for (index, position) in matched.enumerated() {
            if index > 0, matched[index - 1] + 1 == position {
                result.append(contentsOf: (origin[matched[index - 1]] + 1)..<origin[position])
            }
            result.append(origin[position])
        }
        return result
    }
}
