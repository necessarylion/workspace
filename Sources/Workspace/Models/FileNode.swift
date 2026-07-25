import Foundation

/// A lazily-loaded node in a project's file tree.
///
/// Children are only read from disk the first time a folder is expanded, so
/// opening a large repository stays cheap.
@MainActor
@Observable
final class FileNode: Identifiable {
    /// Folders we never walk into — they are large and rarely interesting.
    static let ignoredNames: Set<String> = [
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

    /// Every currently loaded descendant, used for the sidebar search filter.
    func flattenedLoadedDescendants() -> [FileNode] {
        guard let children else { return [] }
        return children.flatMap { [$0] + $0.flattenedLoadedDescendants() }
    }
}
