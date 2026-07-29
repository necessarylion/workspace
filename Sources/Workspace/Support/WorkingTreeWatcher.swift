import Foundation

/// Watches a project's working tree, so a file written by anything but the app
/// reaches the UI. Claude Code in the embedded terminal is the reason: it edits
/// files all day, and the Changes list, the file tree and the open editor all
/// used to keep showing what was there before it started.
///
/// `GitDirectoryWatcher` cannot answer this. It watches the git directory, and
/// an ordinary edit writes nothing inside `.git` — nor is `DispatchSource` the
/// right primitive anyway: it watches one directory and does not recurse, and a
/// repository is a tree. FSEvents does recurse, coalesces a burst into one
/// callback for free, and with `kFSEventStreamCreateFlagFileEvents` names the
/// files rather than the folders, which is what lets the caller reload only the
/// editor whose file actually moved.
///
/// **The paths are filtered here rather than by the caller.** Anything under
/// `.git` belongs to the other watcher and would double every reload, and a
/// build or an `npm install` writes thousands of files nobody is looking at —
/// each one otherwise a `git status`. A batch with nothing left in it is not
/// reported at all.
///
/// The callback runs on the watcher's own queue and can still fire several
/// times for one command; the caller is expected to wait for the burst to end.
/// It is handed nil when the kernel dropped events on us — see ``Sink/deliver``.
final class WorkingTreeWatcher: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.workspace.working-tree-watcher")
    /// Only ever touched on `queue`, which is what makes the unchecked
    /// `Sendable` above true.
    private var stream: FSEventStreamRef?

    /// Fails when FSEvents will not watch the folder — it was deleted, or the
    /// app was never given access to it — so the caller can try again later.
    init?(root: URL, onChange: @escaping @Sendable ([URL]?) -> Void) {
        // A C function pointer, so it captures nothing and reaches everything it
        // needs through the stream's context.
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, eventFlags, _ in
            guard let info,
                  let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String]
            else { return }
            let flags = UnsafeBufferPointer(start: eventFlags, count: count)
            Unmanaged<Sink>.fromOpaque(info).takeUnretainedValue().deliver(paths, flags: flags)
        }

        let sink = Unmanaged.passRetained(Sink(root: root, onChange: onChange))
        var context = FSEventStreamContext(
            version: 0,
            info: sink.toOpaque(),
            retain: nil,
            // The stream owns the sink from here: `FSEventStreamRelease` in
            // `deinit` is what lets go of it.
            release: { pointer in
                guard let pointer else { return }
                Unmanaged<Sink>.fromOpaque(pointer).release()
            },
            copyDescription: nil
        )

        let flags = kFSEventStreamCreateFlagUseCFTypes
            | kFSEventStreamCreateFlagFileEvents
            // Report the first write of a burst straight away rather than a
            // latency later: a single save should not sit for a third of a
            // second before the Changes list notices it.
            | kFSEventStreamCreateFlagNoDefer

        // Long enough that a `git checkout` or a formatter rewriting a folder
        // arrives as one callback, short enough to feel immediate. The caller
        // debounces on top of this anyway.
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [root.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.3,
            FSEventStreamCreateFlags(flags)
        ) else {
            // Nothing took ownership of the sink, so the retain above is ours
            // to undo.
            sink.release()
            return nil
        }

        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return nil
        }
        self.stream = stream
    }

    deinit {
        // On the stream's own queue, so this cannot land in the middle of a
        // callback. Invalidating unschedules it; releasing frees the sink.
        queue.sync {
            guard let stream else { return }
            self.stream = nil
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    /// What the stream holds on to. Deliberately not the watcher itself: the
    /// stream outlives `deinit` by however long the release takes, and a
    /// callback that reached back into a deallocating watcher would be a crash
    /// nobody could reproduce.
    private final class Sink: Sendable {
        private let root: URL
        /// FSEvents reports resolved paths — `/private/var` for `/var` — so the
        /// prefix has to be matched against the resolved root.
        private let resolvedRoot: String
        private let onChange: @Sendable ([URL]?) -> Void

        init(root: URL, onChange: @escaping @Sendable ([URL]?) -> Void) {
            self.root = root.standardizedFileURL
            self.resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
            self.onChange = onChange
        }

        /// **Nil is "something changed and this watcher cannot say what".**
        ///
        /// The kernel's event queue is finite, and when it overflows FSEvents
        /// does not lie about it: it drops the individual events and sets
        /// `MustScanSubDirs` on a folder instead. That is reachable here rather
        /// than theoretical — the filtering above happens after the kernel, not
        /// before, so a build or an `npm install` writing through `.build` and
        /// `node_modules` fills that queue with events this watcher was only
        /// ever going to throw away. `RootChanged` is the same answer for a
        /// different reason: the project folder itself was moved or replaced.
        ///
        /// Reporting the folder we were handed would be worse than useless —
        /// no open document sits at a directory path, so every editor would be
        /// judged unaffected and quietly left showing stale text. Nil tells the
        /// caller to check everything instead.
        func deliver(_ paths: [String], flags: UnsafeBufferPointer<FSEventStreamEventFlags>) {
            let lost = FSEventStreamEventFlags(
                kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged
            )
            guard !flags.contains(where: { $0 & lost != 0 }) else { return onChange(nil) }

            let changed = paths.compactMap(interesting)
            guard !changed.isEmpty else { return }
            onChange(changed)
        }

        /// The URL to report for one event path, or nil for the ones the app
        /// does not want to hear about. The answer is rebuilt under the URL the
        /// project was added as rather than the resolved one, because that is
        /// the namespace every open document and every file tree node lives in;
        /// standardized, because that is how the callers compare it.
        private func interesting(_ path: String) -> URL? {
            if path == resolvedRoot { return root }
            guard path.hasPrefix(resolvedRoot + "/") else { return nil }
            let relative = path.dropFirst(resolvedRoot.count + 1)
            guard !relative.split(separator: "/").contains(where: {
                FileNode.ignoredNames.contains(String($0))
            }) else { return nil }
            return root.appending(path: String(relative)).standardizedFileURL
        }
    }
}
