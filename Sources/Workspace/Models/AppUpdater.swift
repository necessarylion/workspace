import AppKit
import Foundation

/// A version the way a release tag writes it — `v0.3.1` — compared number by
/// number, so 0.10 lands *after* 0.9 rather than before it the way sorting the
/// text would put it.
struct AppVersion: Comparable, Sendable, CustomStringConvertible {
    /// The dotted numbers, most significant first. A missing place counts as a
    /// zero, so `1.2` and `1.2.0` are one version.
    private let numbers: [Int]
    /// Whatever follows a `-`: a pre-release, which comes *before* the release
    /// of the same numbers, the way semantic versioning means it.
    private let prerelease: String?
    /// As written, minus the `v` — what the UI shows.
    let text: String

    init(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let stripped = trimmed.hasPrefix("v") ? String(trimmed.dropFirst()) : trimmed
        // Build metadata (`+2024abcd`) says nothing about precedence.
        let withoutBuild = stripped.split(separator: "+", maxSplits: 1).first ?? ""
        let parts = withoutBuild.split(separator: "-", maxSplits: 1)
        numbers = (parts.first ?? "").split(separator: ".").map { part in
            // `1.2.0rc` and friends: take the number and drop the rest.
            Int(part.prefix { $0.isNumber }) ?? 0
        }
        prerelease = parts.count > 1 ? String(parts[1]) : nil
        text = stripped.isEmpty ? "0" : stripped
    }

    var description: String { text }

    private func number(at index: Int) -> Int {
        index < numbers.count ? numbers[index] : 0
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        for index in 0..<max(lhs.numbers.count, rhs.numbers.count) {
            let left = lhs.number(at: index)
            let right = rhs.number(at: index)
            if left != right { return left < right }
        }
        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, nil), (nil, _?): return false
        case (_?, nil): return true
        case (let left?, let right?): return left.compare(right, options: .numeric) == .orderedAscending
        }
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }
}

/// A published release, as the app needs it: which version, what changed, and
/// the one asset it can install itself from.
struct AppRelease: Sendable, Equatable {
    let version: AppVersion
    /// The release's own title, falling back to the tag.
    let title: String
    /// The Markdown body, shown in Settings.
    let notes: String
    let page: URL
    /// The zip CI attaches to every release. The disk image beside it is for a
    /// person with a mouse; a zip is what `ditto` unpacks without mounting
    /// anything.
    let archive: URL
    let size: Int64
    let published: Date?
}

/// Checking for a new version of Workspace, fetching it, and swapping it in.
///
/// The releases are read straight from the GitHub API over HTTPS rather than
/// through `gh`: `gh` is a tool the *user* installs and signs in to, and the app
/// has to be able to update itself on a Mac that has neither. Nothing about the
/// update needs an account — a release asset is a public URL.
///
/// Left to itself the whole thing is quiet: it checks every six hours, and with
/// automatic installing on it downloads and unpacks in the background. It stops
/// there. The last step — replacing the running app and starting it again — is
/// always a button, because it closes whatever you were in the middle of.
@MainActor
@Observable
final class AppUpdater {
    static let shared = AppUpdater()

    /// Where the app is in the update it is doing, if any.
    enum Stage: Equatable {
        /// Nothing asked yet, this run.
        case idle
        case checking
        case upToDate
        /// Newer than this copy, not fetched yet.
        case available(AppRelease)
        /// Fetching, with the fraction of the bytes that have arrived.
        case downloading(AppRelease, Double)
        /// Unpacked and waiting for the relaunch that swaps it in.
        case ready(AppRelease)
        case failed(String)
    }

    private(set) var stage: Stage = .idle
    private(set) var lastChecked: Date?

    var checksAutomatically: Bool {
        didSet { UserDefaults.standard.set(checksAutomatically, forKey: Keys.checks) }
    }

    /// With this on, an update found by an automatic check is downloaded and
    /// unpacked without being asked — only the relaunch is left to you.
    var installsAutomatically: Bool {
        didSet { UserDefaults.standard.set(installsAutomatically, forKey: Keys.installs) }
    }

    /// Bumped by ``requestUpdatesTab()``; Settings watches it and moves to the
    /// Updates tab. A counter rather than a flag, so asking twice works.
    private(set) var updatesTabRequest = 0

    /// What this bundle says it is. `Scripts/bundle.sh` stamps it from the git
    /// tag, so a build made from an untagged tree reports 0.0.0 and every
    /// release is newer than it.
    let current = AppVersion(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0")

    /// The unpacked app waiting to be swapped in.
    private var staged: URL?
    /// The check or download running now — one at a time.
    private var work: Task<Void, Never>?
    /// The six-hourly check, started once per launch.
    private var schedule: Task<Void, Never>?

    /// How long between automatic checks. A release is a rare event and the API
    /// is asked without a token, which is rate limited by IP address.
    private static let interval: TimeInterval = 6 * 60 * 60

    private enum Keys {
        static let checks = "updates.checkAutomatically"
        static let installs = "updates.installAutomatically"
        static let lastChecked = "updates.lastChecked"
    }

    private init() {
        let defaults = UserDefaults.standard
        // Both start on. `object(forKey:)` rather than `bool(forKey:)`, which
        // cannot tell a switch turned off from one never touched.
        checksAutomatically = defaults.object(forKey: Keys.checks) as? Bool ?? true
        installsAutomatically = defaults.object(forKey: Keys.installs) as? Bool ?? true
        lastChecked = defaults.object(forKey: Keys.lastChecked) as? Date
    }

    // MARK: - What the UI asks

    /// The release this update is about, whichever step it has reached.
    var pending: AppRelease? {
        switch stage {
        case .available(let release), .downloading(let release, _), .ready(let release):
            return release
        case .idle, .checking, .upToDate, .failed:
            return nil
        }
    }

    var isBusy: Bool {
        switch stage {
        case .checking, .downloading: return true
        default: return false
        }
    }

    /// The bundle that would be replaced.
    var installLocation: URL { Bundle.main.bundleURL }

    /// Whether the swap can happen at all. The *folder* has to be writable,
    /// because the new app is moved into place beside the old one — which rules
    /// out a copy still running from a mounted disk image.
    var canInstall: Bool {
        FileManager.default.isWritableFile(atPath: installLocation.deletingLastPathComponent().path)
    }

    /// A build running out of Xcode's products folder is not something to
    /// overwrite behind the user's back — the next `Scripts/run.sh` would undo
    /// it anyway. Only an installed copy updates itself unasked; the buttons in
    /// Settings still work everywhere.
    var isInstalledCopy: Bool {
        installLocation.path.contains("/Applications/")
    }

    /// Asks Settings to show the Updates tab the next time it is on screen.
    func requestUpdatesTab() { updatesTabRequest += 1 }

    // MARK: - Checking

    /// The six-hourly check. Called once, from the window's `task`.
    func startAutomaticChecks() {
        guard schedule == nil else { return }
        schedule = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                // Nothing to do while one is already found and waiting: asking
                // again would only fetch the same release a second time.
                if checksAutomatically, isDue, !isBusy, pending == nil {
                    await perform(automatic: true)
                }
                try? await Task.sleep(for: .seconds(Self.interval))
            }
        }
    }

    /// A check made from a button, whatever the switches say.
    func check() {
        guard !isBusy else { return }
        // An update already unpacked is the answer to "is there a new one".
        if case .ready = stage { return }
        work = Task { await perform(automatic: false) }
    }

    /// True when the last check is older than the interval, or never happened.
    private var isDue: Bool {
        guard let lastChecked else { return true }
        return Date().timeIntervalSince(lastChecked) >= Self.interval
    }

    private func perform(automatic: Bool) async {
        stage = .checking
        do {
            let release = try await UpdateFetch.latest()
            lastChecked = Date()
            UserDefaults.standard.set(lastChecked, forKey: Keys.lastChecked)

            guard release.version > current else {
                stage = .upToDate
                return
            }
            stage = .available(release)

            if automatic, installsAutomatically, canInstall, isInstalledCopy {
                await fetch(release)
            }
        } catch {
            stage = .failed(message(for: error))
        }
    }

    // MARK: - Fetching

    /// Downloads and unpacks the release now waiting, from a button.
    func download() {
        guard case .available(let release) = stage else { return }
        work = Task { await fetch(release) }
    }

    private func fetch(_ release: AppRelease) async {
        stage = .downloading(release, 0)
        do {
            let app = try await UpdateFetch.download(release) { [weak self] fraction in
                Task { @MainActor in
                    guard let self else { return }
                    // Only while this download is still the thing happening: a
                    // late report must not reopen the bar over whatever
                    // replaced it.
                    guard case .downloading = self.stage else { return }
                    self.stage = .downloading(release, fraction)
                }
            }
            staged = app
            stage = .ready(release)
        } catch {
            stage = .failed(message(for: error))
        }
    }

    // MARK: - Installing

    /// Hands the swap to a script and quits, which is the only way round the
    /// fact that the app cannot replace the copy it is running from.
    func installAndRelaunch() {
        guard case .ready = stage, let source = staged else { return }
        do {
            try UpdateFetch.handOff(source: source, destination: installLocation)
        } catch {
            stage = .failed("Could not start the install: \(error.localizedDescription)")
            return
        }
        NSApp.terminate(nil)
    }

    private func message(for error: Error) -> String {
        (error as? UpdateError)?.errorDescription ?? error.localizedDescription
    }
}

/// What can go wrong between GitHub and /Applications.
enum UpdateError: LocalizedError {
    case noRelease
    case rateLimited
    case http(Int)
    case noArchive(String)
    case unpack(String)
    case notAnApp

    var errorDescription: String? {
        switch self {
        case .noRelease:
            "No published release found — check again once one is out."
        case .rateLimited:
            "GitHub is rate limiting this Mac. Try again in an hour."
        case .http(let code):
            "GitHub answered \(code)."
        case .noArchive(let tag):
            "Release \(tag) has no Workspace.zip attached, so it cannot be installed from here."
        case .unpack(let detail):
            "The download could not be unpacked: \(detail)"
        case .notAnApp:
            "The download did not contain a Workspace app."
        }
    }
}

/// The network and disk half of an update: asking GitHub what the latest
/// release is, fetching its zip, unpacking it, and writing the script that
/// swaps the bundle over. None of it touches the UI, so none of it is on the
/// main actor.
enum UpdateFetch {
    /// Where releases come from. One repository, spelled out here rather than
    /// guessed from the `origin` of whatever folder happens to be open — this
    /// is the app updating *itself*.
    static let repository = "necessarylion/workspace"

    /// The API rejects a request that names nobody.
    private static let userAgent = "Workspace-macOS (+https://github.com/necessarylion/workspace)"

    // MARK: - The latest release

    static func latest() async throws -> AppRelease {
        let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        try verify(response)

        let decoder = JSONDecoder()
        // `tag_name` → `tagName`, `browser_download_url` → `browserDownloadUrl`.
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        let payload = try decoder.decode(Payload.self, from: data)

        // `/releases/latest` skips drafts and pre-releases itself; this is the
        // belt to that pair of braces.
        guard !payload.draft, !payload.prerelease else { throw UpdateError.noRelease }

        guard let asset = payload.assets.first(where: { $0.name.caseInsensitiveCompare("Workspace.zip") == .orderedSame })
            ?? payload.assets.first(where: { $0.name.lowercased().hasSuffix(".zip") }),
            let archive = URL(string: asset.browserDownloadUrl)
        else { throw UpdateError.noArchive(payload.tagName) }

        return AppRelease(
            version: AppVersion(payload.tagName),
            title: payload.name.flatMap { $0.isEmpty ? nil : $0 } ?? payload.tagName,
            notes: payload.body ?? "",
            page: URL(string: payload.htmlUrl) ?? URL(string: "https://github.com/\(repository)/releases")!,
            archive: archive,
            size: asset.size,
            published: payload.publishedAt
        )
    }

    private static func verify(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        switch http.statusCode {
        case 200..<300: return
        // A repository with no release yet answers the same way a private one
        // does, and neither is something to alarm anybody about.
        case 404: throw UpdateError.noRelease
        case 403, 429: throw UpdateError.rateLimited
        default: throw UpdateError.http(http.statusCode)
        }
    }

    private struct Payload: Decodable {
        let tagName: String
        let name: String?
        let body: String?
        let htmlUrl: String
        let draft: Bool
        let prerelease: Bool
        let publishedAt: Date?
        let assets: [Asset]

        struct Asset: Decodable {
            let name: String
            let browserDownloadUrl: String
            let size: Int64
        }
    }

    // MARK: - Downloading

    /// Fetches the release's zip and unpacks it, answering with the app bundle
    /// inside. `progress` is called as the bytes arrive.
    static func download(
        _ release: AppRelease,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        var request = URLRequest(url: release.archive, timeoutInterval: 120)
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        // The release already said how many bytes the asset is, which is what
        // the bar falls back to if the response itself does not say.
        let fetch = DownloadTask(expected: release.size, report: progress)
        let (downloaded, response) = try await fetch.run(request)

        let manager = FileManager.default
        do {
            // A refusal has a body like anything else, so the file it was
            // written to goes with the error rather than staying in /tmp.
            if let response { try verify(response) }
        } catch {
            try? manager.removeItem(at: downloaded)
            throw error
        }

        // The name is what the hand-off script matches on before deleting it.
        let work = manager.temporaryDirectory
            .appendingPathComponent("workspace-update-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: work, withIntermediateDirectories: true)

        let archive = work.appendingPathComponent("Workspace.zip")
        try manager.moveItem(at: downloaded, to: archive)

        // `ditto -x -k` is what made the zip on the release runner, and the one
        // unarchiver that puts a bundle back with its symlinks, its resource
        // forks and its executable bits intact.
        let unpacked = work.appendingPathComponent("unpacked", isDirectory: true)
        let result = await Shell.run(["ditto", "-x", "-k", archive.path, unpacked.path], timeout: 300)
        guard result.isSuccess else {
            try? manager.removeItem(at: work)
            throw UpdateError.unpack(result.failureMessage)
        }
        try? manager.removeItem(at: archive)

        guard let app = try manager
            .contentsOfDirectory(at: unpacked, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension == "app" }),
            // Not a full check — an ad-hoc signature proves nothing about who
            // made it — but enough to know the swap will not put a folder with
            // nothing runnable in it where the app used to be.
            manager.isExecutableFile(atPath: app.appendingPathComponent("Contents/MacOS/Workspace").path)
        else {
            try? manager.removeItem(at: work)
            throw UpdateError.notAnApp
        }
        return app
    }

    // MARK: - The swap

    /// Starts a script that waits for this process to go, replaces the bundle
    /// and opens it again.
    ///
    /// It has to be another process: the app is running out of the very folder
    /// being replaced. A rename inside the same directory is what makes it
    /// safe — the old copy is set aside rather than deleted, and put back if
    /// the new one fails to land.
    static func handOff(source: URL, destination: URL) throws {
        // …/workspace-update-XXX/unpacked/Workspace.app → …/workspace-update-XXX
        let staging = source.deletingLastPathComponent().deletingLastPathComponent()
        let script = """
        #!/bin/bash
        source=\(Shell.quote(source.path))
        destination=\(Shell.quote(destination.path))
        staging=\(Shell.quote(staging.path))
        backup="$destination.old-$$"

        # Wait for Workspace to quit — `kill -0` only asks whether it is still
        # there. A minute is far longer than quitting takes; going ahead after
        # it is better than leaving a half-finished update forever.
        for _ in $(seq 1 600); do
            kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null || break
            sleep 0.1
        done

        rm -rf "$backup"
        mv "$destination" "$backup" || exit 1
        if ditto "$source" "$destination"; then
            rm -rf "$backup"
        else
            # Put the old one back and open that instead, so a failed update
            # never costs anybody their app.
            rm -rf "$destination"
            mv "$backup" "$destination"
            open "$destination"
            exit 1
        fi

        # It came over HTTPS from our own code, so nothing marked it as a
        # download; cleared anyway, since a quarantined bundle would meet the
        # user with Gatekeeper's refusal on the very next launch.
        xattr -dr com.apple.quarantine "$destination" 2>/dev/null || true
        open "$destination"

        # Only ever the folder this update made.
        case "$staging" in
            */workspace-update-*) rm -rf "$staging" ;;
        esac
        """

        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("workspace-update-\(UUID().uuidString).sh")
        try script.write(to: file, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [file.path]
        // Deliberately not waited on: this app is about to be gone. A child
        // outlives its parent on macOS, which is the whole point.
        try process.run()
    }
}

/// One download, with the bytes reported as they arrive.
///
/// **Not** `URLSession.download(for:delegate:)`, which is what this was and is
/// why the bar sat at 0% until the download finished and then jumped to done:
/// the async call installs a download delegate of its own to catch the finished
/// file, and the delegate handed to it never sees a single
/// `URLSessionDownloadDelegate` callback — measured against the real release
/// asset, 0 calls that way against 297 this way. So the session gets a delegate
/// the way it always took one, and the classic task is bridged back to `async`
/// with a continuation.
private final class DownloadTask: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    /// How big the asset is according to the release. Used when the response
    /// itself does not say — a redirected or chunked body carries no
    /// `Content-Length`, and without a total there is no fraction to report.
    private let expected: Int64
    /// `@Sendable`; the unchecked conformance is only there because NSObject is
    /// not Sendable itself.
    private let report: @Sendable (Double) -> Void

    /// Everything below is touched on the session's own serial delegate queue,
    /// except the continuation, which is set before the task is started.
    private var continuation: CheckedContinuation<(URL, URLResponse?), Error>?
    /// Where the finished file was put; see `didFinishDownloadingTo`.
    private var file: URL?

    init(expected: Int64, report: @escaping @Sendable (Double) -> Void) {
        self.expected = expected
        self.report = report
    }

    func run(_ request: URLRequest) async throws -> (URL, URLResponse?) {
        // A session with a delegate holds it until it is invalidated, which is
        // what the `defer` is for.
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            session.downloadTask(with: request).resume()
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        // -1 until the server says how long the body is.
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : expected
        guard total > 0 else { return }
        // A release whose recorded size is a little short of what actually
        // arrives must not push the bar past its end.
        report(min(Double(totalBytesWritten) / Double(total), 1))
    }

    /// The downloaded file is deleted the moment this returns, so it is moved
    /// out here rather than in the caller.
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("workspace-download-\(UUID().uuidString).zip")
        do {
            try FileManager.default.moveItem(at: location, to: destination)
            file = destination
        } catch {
            finish(.failure(error))
        }
    }

    /// The one place the download ends, success or failure — a task that fails
    /// before any bytes land never reaches `didFinishDownloadingTo`.
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            finish(.failure(error))
        } else if let file {
            finish(.success((file, task.response)))
        } else {
            finish(.failure(URLError(.cannotOpenFile)))
        }
    }

    private func finish(_ result: Result<(URL, URLResponse?), Error>) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
    }
}
