import Foundation

/// Watches a repository's git directory, so git run *outside* the app reaches
/// the UI. A `git checkout` typed in the embedded terminal used to leave the
/// branch name in the sidebar, the history on the dashboard and the Files tab
/// all showing the branch the user had just left.
///
/// Git never edits a file in place: it writes `HEAD.lock`, `index.lock` and the
/// rest next to the real file and renames them over it. Every one of those is
/// an entry appearing and disappearing in the git directory itself, so a single
/// watch on that one directory catches a checkout, a commit, a merge and a
/// fetch alike — no polling, and no walking `refs/`.
///
/// The handler runs on the watcher's own queue and can fire several times for
/// one command; the caller is expected to wait for the burst to end.
final class GitDirectoryWatcher: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.workspace.git-directory-watcher")
    private let directory: URL
    private let onChange: @Sendable () -> Void

    /// Everything below is touched on `queue` alone, which is what makes the
    /// unchecked `Sendable` above true.
    private var source: DispatchSourceFileSystemObject?
    private var retriesLeft = 5

    /// `repository` is the working tree. The git directory is usually `.git`
    /// inside it, but a linked worktree keeps a `.git` *file* pointing at the
    /// real one — and that is where its own HEAD and index live. Fails when the
    /// folder is not a repository at all, so the caller can try again later.
    init?(repository: URL, onChange: @escaping @Sendable () -> Void) {
        guard let directory = Self.gitDirectory(for: repository) else { return nil }
        self.directory = directory
        self.onChange = onChange
        queue.sync { arm() }
    }

    deinit {
        // `source` is only ever read on `queue`, and cancelling closes the
        // descriptor through the cancel handler below.
        queue.sync {
            retriesLeft = 0
            source?.cancel()
            source = nil
        }
    }

    private func arm() {
        guard source == nil else { return }
        let descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else { return retryLater() }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename, .revoke],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            guard let self, let flags = self.source?.data else { return }
            if flags.contains(.write) { self.onChange() }
            // The git directory itself went — a repository re-cloned or
            // re-initialised underneath us. The descriptor is dead now, so
            // watch the new one instead of going quiet for good.
            if !flags.isDisjoint(with: [.delete, .rename, .revoke]) {
                self.source?.cancel()
                self.source = nil
                self.onChange()
                self.retryLater()
            }
        }
        source.setCancelHandler { close(descriptor) }
        self.source = source
        source.resume()
    }

    /// Only ever after the directory went missing, and only a few times: a
    /// folder that stopped being a repository should not be polled forever.
    private func retryLater() {
        guard retriesLeft > 0 else { return }
        retriesLeft -= 1
        queue.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.arm()
        }
    }

    private static func gitDirectory(for repository: URL) -> URL? {
        let dotGit = repository.appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) else {
            return nil
        }
        if isDirectory.boolValue { return dotGit }

        // A linked worktree or a submodule: the file holds one "gitdir: <path>"
        // line, absolute or relative to the working tree.
        guard let text = try? String(contentsOf: dotGit, encoding: .utf8),
              let line = text.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") })
        else { return nil }
        let path = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty else { return nil }
        return path.hasPrefix("/")
            ? URL(fileURLWithPath: path)
            : repository.appendingPathComponent(path).standardizedFileURL
    }
}
