import AppKit
import Foundation

/// Everything the Files tab does to the disk: dropping files into a folder,
/// renaming one, and deleting one. Pure filesystem work with no UI and no state,
/// so it can run off the main actor — a dropped folder can be large.
///
/// `WorkspaceStore.importFiles`, `renameFile` and `deleteFiles` are the callers;
/// they refresh the tree and put the outcome in the status bar.
enum FileOperations {
    /// A drag from outside the repository copies, a drag from inside it moves —
    /// the same rule Finder uses between and within a volume, and the one that
    /// makes dragging a file up a folder in the tree do what it looks like.
    enum Transfer: Sendable {
        case copy, move

        var pastTense: String { self == .copy ? "Copied" : "Moved" }
        var verb: String { self == .copy ? "copy" : "move" }
    }

    struct Result: Sendable {
        /// The files and folders now sitting in the destination.
        var finished: [URL] = []
        /// Dropped on the folder they are already in, so there is nothing to do.
        var skipped = 0
        /// One line per source that could not be handled.
        var errors: [String] = []
    }

    /// Puts each of `sources` in `folder`, keeping its name unless something is
    /// already called that — then it becomes "name 2", "name 3" and so on, the
    /// way Finder numbers a duplicate, so a drop never overwrites.
    static func transfer(_ kind: Transfer, _ sources: [URL], into folder: URL) -> Result {
        var result = Result()
        let manager = FileManager.default

        for source in sources.map(\.standardizedFileURL) {
            guard manager.fileExists(atPath: source.path) else {
                result.errors.append("\(source.lastPathComponent) is gone")
                continue
            }
            // Dropped back where it came from.
            if source.deletingLastPathComponent() == folder.standardizedFileURL {
                result.skipped += 1
                continue
            }
            // A folder cannot go inside itself or inside one of its own
            // descendants — copying that way never ends.
            if isDescendant(folder, of: source) {
                result.errors.append("\(source.lastPathComponent) cannot \(kind.verb) into itself")
                continue
            }

            let destination = uniqueURL(for: source.lastPathComponent, in: folder)
            do {
                switch kind {
                case .copy: try manager.copyItem(at: source, to: destination)
                case .move: try manager.moveItem(at: source, to: destination)
                }
                result.finished.append(destination)
            } catch {
                result.errors.append("\(source.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return result
    }

    enum RenameOutcome: Sendable {
        case renamed(URL)
        /// The name typed is the name it already has.
        case unchanged
        case failed(String)
    }

    /// Renames one file or folder in place. An existing name is refused rather
    /// than numbered around the way a drop is, because the user typed this one
    /// and silently getting "name 2" is not what they asked for.
    static func rename(_ url: URL, to name: String) -> RenameOutcome {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return .failed("a name cannot be empty") }
        guard !name.contains("/"), name != ".", name != ".." else {
            return .failed("\(name) is not a valid name")
        }
        let destination = url.deletingLastPathComponent().appendingPathComponent(name)
        guard destination.standardizedFileURL != url.standardizedFileURL else { return .unchanged }
        // A case-only rename ("readme" → "README") looks like a collision on a
        // case-insensitive disk; the move itself handles that one.
        if FileManager.default.fileExists(atPath: destination.path),
           destination.path.lowercased() != url.path.lowercased() {
            return .failed("\(name) already exists")
        }
        do {
            try FileManager.default.moveItem(at: url, to: destination)
            return .renamed(destination)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// A second copy beside the original, named the way `transfer` names one —
    /// Finder's Duplicate. It cannot go through `transfer`, which treats a file
    /// dropped in its own folder as nothing to do.
    static func duplicate(_ urls: [URL]) -> Result {
        var result = Result()
        for url in urls {
            let destination = uniqueURL(for: url.lastPathComponent, in: url.deletingLastPathComponent())
            do {
                try FileManager.default.copyItem(at: url, to: destination)
                result.finished.append(destination)
            } catch {
                result.errors.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return result
    }

    /// Puts files in the Trash rather than unlinking them, so a wrong delete is
    /// one ⌘Z away in Finder and never loses work.
    static func trash(_ urls: [URL]) -> Result {
        var result = Result()
        for url in urls {
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                result.finished.append(url)
            } catch {
                result.errors.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return result
    }

    /// `name` inside `folder`, or a name based on it that nothing there uses yet.
    private static func uniqueURL(for name: String, in folder: URL) -> URL {
        let candidate = folder.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: candidate.path) else { return candidate }

        // "archive.tar.gz" numbers as "archive.tar 2.gz": only the last
        // extension is kept apart, which is what `URL` gives us.
        let base = candidate.deletingPathExtension().lastPathComponent
        let ext = candidate.pathExtension
        for index in 2...999 {
            var next = folder.appendingPathComponent("\(base) \(index)")
            if !ext.isEmpty { next = next.appendingPathExtension(ext) }
            if !FileManager.default.fileExists(atPath: next.path) { return next }
        }
        return candidate
    }

    private static func isDescendant(_ url: URL, of folder: URL) -> Bool {
        let folderPath = folder.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        return path == folderPath || path.hasPrefix(folderPath + "/")
    }
}
