import Foundation

/// A lazily-loaded node in a project's file tree.
///
/// Children are only read from disk the first time a folder is expanded, so
/// opening a large repository stays cheap.
@MainActor
@Observable
final class FileNode: Identifiable {
    /// Folders we never walk into — they are large and rarely interesting.
    /// `nonisolated` because `WorkingTreeWatcher` filters against this on its
    /// own queue: the same folders that are not worth listing are not worth
    /// reloading the world for either.
    nonisolated static let ignoredNames: Set<String> = [
        ".git", ".build", ".swiftpm", "node_modules", "DerivedData", ".DS_Store"
    ]

    nonisolated let url: URL
    nonisolated let isDirectory: Bool
    private(set) var children: [FileNode]?

    var isExpanded = false {
        didSet {
            if isExpanded { loadChildrenIfNeeded() }
        }
    }

    nonisolated var id: URL { url }
    nonisolated var name: String { url.lastPathComponent }

    init(url: URL, isDirectory: Bool) {
        self.url = url
        self.isDirectory = isDirectory
    }

    /// Builds a node for `url`, asking the filesystem whether it is a folder.
    convenience init(url: URL) {
        let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        self.init(url: url, isDirectory: isDir)
    }

    func loadChildrenIfNeeded() {
        guard isDirectory, children == nil else { return }
        reloadChildren()
    }

    func reloadChildren() {
        guard isDirectory else { return }
        // Dotfiles are shown: `.env`, `.mcp.json`, `.github` and friends are
        // part of a repository, not clutter. The few that are never worth
        // opening are named in `ignoredNames` instead.
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? []

        children = contents
            .filter { !Self.ignoredNames.contains($0.lastPathComponent) }
            .map { child in
                let isDir = (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                return FileNode(url: child, isDirectory: isDir)
            }
            // Folders first, then files, each alphabetical.
            .sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }

    /// Re-reads this folder after something changed inside it, reusing the nodes
    /// that are still there. `reloadChildren` builds every node again, which
    /// collapses each expanded folder under it — fine for the reload button,
    /// wrong after a drop, where the tree should look exactly as it did plus the
    /// new files.
    func refreshChildren() {
        guard isDirectory, let current = children else { return }
        let existing = Dictionary(current.map { ($0.url, $0) }, uniquingKeysWith: { first, _ in first })
        reloadChildren()
        children = children?.map { fresh in
            guard let old = existing[fresh.url], old.isDirectory == fresh.isDirectory else { return fresh }
            return old
        }
    }

    /// Re-reads every folder the tree has already read, top to bottom. Used
    /// after something outside the tree changed the files — a git command, a
    /// rename — where the folder that changed is not known, only that something
    /// did. Costs one directory listing per expanded folder and keeps every one
    /// of them open.
    func refreshLoadedTree() {
        guard isDirectory, children != nil else { return }
        refreshChildren()
        for child in children ?? [] where child.isDirectory && child.children != nil {
            child.refreshLoadedTree()
        }
    }

    /// The node for `url`, if the tree has read that far. Nothing is loaded from
    /// disk on the way — an unexpanded folder simply has no node to find.
    func loadedNode(at url: URL) -> FileNode? {
        let target = url.standardizedFileURL
        if self.url.standardizedFileURL == target { return self }
        guard isDirectory,
              target.path.hasPrefix(self.url.standardizedFileURL.path + "/"),
              let children
        else { return nil }
        for child in children {
            if let match = child.loadedNode(at: target) { return match }
        }
        return nil
    }

    /// Every currently loaded descendant, used for the sidebar search filter.
    func flattenedLoadedDescendants() -> [FileNode] {
        guard let children else { return [] }
        return children.flatMap { [$0] + $0.flattenedLoadedDescendants() }
    }
}
