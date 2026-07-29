import CryptoKit
import SwiftUI

/// Where a person's picture lives, worked out from what the host already told
/// us — a login, an email address, or a link the API handed over itself.
///
/// Nothing here asks the network a question: every address is built from data
/// that arrived with the pull request, the comment or the commit. A wrong guess
/// costs one failed image load and the initials show instead.
enum AvatarURL {
    /// The size asked for, in points before the screen's scale. Small enough to
    /// stay cheap, large enough for the biggest disc the app draws.
    private static let pixelSize = 96

    /// A GitHub user's picture from their login.
    ///
    /// `host` is the host the pull request itself lives on, so an Enterprise
    /// checkout does not end up showing the github.com user who happens to share
    /// a login. It comes from the PR's own URL, and github.com is the default.
    static func gitHub(login: String?, host: String? = nil) -> URL? {
        guard let login = login?.trimmingCharacters(in: .whitespaces),
              isPlausibleGitHubLogin(login)
        else { return nil }

        guard let host, !host.hasSuffix("github.com") else {
            return URL(string: "https://avatars.githubusercontent.com/\(login)?size=\(pixelSize)")
        }
        // Enterprise serves the same redirect off the user's own page.
        return URL(string: "https://\(host)/\(login).png?size=\(pixelSize)")
    }

    /// A picture for whoever authored a commit locally, using only the email
    /// address git recorded.
    ///
    /// GitHub's own no-reply addresses carry the account in them, which gives an
    /// exact answer; everything else falls back to Gravatar, which answers 404
    /// for an address it does not know, so the initials take over.
    static func gitIdentity(email: String?) -> URL? {
        let address = (email ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        guard address.contains("@") else { return nil }

        if address.hasSuffix("@users.noreply.github.com") {
            let local = address.replacingOccurrences(of: "@users.noreply.github.com", with: "")
            // Newer addresses read `12345+login`; the number is the account id.
            if let plus = local.firstIndex(of: "+"),
               let id = Int(local[local.startIndex..<plus]) {
                return URL(string: "https://avatars.githubusercontent.com/u/\(id)?size=\(pixelSize)")
            }
            return gitHub(login: local)
        }

        return gravatar(email: address)
    }

    /// `Name <name@example.com>` — the one-line identity Bitbucket sends for a
    /// commit — turned into a picture for that address.
    static func gitIdentity(raw: String?) -> URL? {
        guard let raw, let open = raw.firstIndex(of: "<"), let close = raw.lastIndex(of: ">"),
              open < close
        else { return nil }
        return gitIdentity(email: String(raw[raw.index(after: open)..<close]))
    }

    /// Gravatar's picture for an address, or nothing at all: `d=404` keeps the
    /// service from answering with its generic silhouette, which would read as a
    /// real face that is not there.
    static func gravatar(email: String) -> URL? {
        let normalised = email.trimmingCharacters(in: .whitespaces).lowercased()
        let digest = Insecure.MD5.hash(data: Data(normalised.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return URL(string: "https://www.gravatar.com/avatar/\(hex)?s=\(pixelSize)&d=404")
    }

    /// A link the host handed us, kept only when it is a usable web address.
    /// Bitbucket Data Center sometimes sends a path instead of a URL.
    static func hosted(_ raw: String?) -> URL? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty,
              let url = URL(string: raw), url.scheme == "https" || url.scheme == "http"
        else { return nil }
        return url
    }

    /// A login is letters, digits and hyphens. A display name with spaces or an
    /// `app/…` bot handle is not one, and asking for it would only 404.
    private static func isPlausibleGitHubLogin(_ login: String) -> Bool {
        guard !login.isEmpty, login.count <= 39, login != "unknown" else { return false }
        return login.allSatisfy { ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "-" }
    }
}

/// Downloads avatars once and keeps them.
///
/// Lists redraw constantly while scrolling, so the same handful of pictures
/// would otherwise be fetched over and over. Addresses that fail are remembered
/// too — a Gravatar 404 or a private Bitbucket instance should cost one request,
/// not one per row.
@MainActor
final class AvatarLoader {
    static let shared = AvatarLoader()

    private let cache = NSCache<NSURL, NSImage>()
    private var failed: Set<URL> = []
    private var inFlight: [URL: Task<NSImage?, Never>] = [:]

    private init() { cache.countLimit = 256 }

    /// What is already in memory, for a view that is being drawn right now.
    func cached(_ url: URL) -> NSImage? { cache.object(forKey: url as NSURL) }

    /// The picture at `url`, downloading it if this is the first time it is
    /// asked for. Concurrent callers share the one request.
    func image(for url: URL) async -> NSImage? {
        if let image = cached(url) { return image }
        if failed.contains(url) { return nil }
        if let task = inFlight[url] { return await task.value }

        let task = Task { [weak self] in
            let image = await AvatarLoader.download(url)
            self?.finish(url, image: image)
            return image
        }
        inFlight[url] = task
        return await task.value
    }

    private func finish(_ url: URL, image: NSImage?) {
        if let image {
            cache.setObject(image, forKey: url as NSURL)
        } else {
            failed.insert(url)
        }
        inFlight[url] = nil
    }

    /// Fetches the bytes and turns them into an image. Anything that is not a
    /// 200 with decodable image data counts as "this person has no picture".
    private static func download(_ url: URL) async -> NSImage? {
        var request = URLRequest(url: url)
        request.cachePolicy = .returnCacheDataElseLoad
        request.timeoutInterval = 15

        guard let (data, response) = try? await URLSession.shared.data(for: request) else {
            return nil
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            return nil
        }
        return NSImage(data: data)
    }
}

/// Someone's picture, drawn as a disc.
///
/// Until the picture is there — and forever, when the host has none — it draws
/// the initials in a colour taken from the name itself, so the same person is
/// the same disc on every row even while nothing has loaded.
@MainActor
struct AuthorAvatar: View {
    let name: String
    var url: URL?
    var size: CGFloat = 16

    @State private var image: NSImage?

    init(name: String, url: URL? = nil, size: CGFloat = 16) {
        self.name = name
        self.url = url
        self.size = size
        // Primed from the cache so a row that scrolls back into view shows the
        // face immediately instead of flashing its initials first.
        _image = State(initialValue: url.flatMap { AvatarLoader.shared.cached($0) })
    }

    private var initials: String {
        let words = name
            .split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "_" || $0 == "." })
            .prefix(2)
        let letters = words.compactMap(\.first)
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }

    /// A stable hue per name: the same string always lands on the same wheel
    /// position, and no name lands on a colour the pull request states use for
    /// meaning — those are read, this one is only told apart.
    private var tint: Color {
        let hash = name.unicodeScalars.reduce(UInt32(7)) { $0 &* 31 &+ $1.value }
        return Color(hue: Double(hash % 360) / 360, saturation: 0.45, brightness: 0.75)
    }

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .transition(.opacity)
            } else {
                Text(initials)
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: size, height: size)
                    .background(tint.opacity(0.22))
                    .transition(.opacity)
            }
        }
        // The initials give way to the face rather than being swapped for it.
        // A pull request opened for the first time asks for every picture on it
        // at once and they land one at a time, so without this the whole page
        // speckles. Opacity and nothing else: fifty discs growing into place is
        // a page that cannot be read while it settles, and the two sides are the
        // same disc at the same size anyway. It only ever runs on first sight —
        // the initialiser primes a face the cache already has.
        .animation(ViewerMotion.isReduced ? nil : .easeOut(duration: 0.2), value: image != nil)
        .frame(width: size, height: size)
        .clipShape(Circle())
        .help(name)
        .task(id: url) {
            guard let url else {
                image = nil
                return
            }
            if let cached = AvatarLoader.shared.cached(url) {
                image = cached
                return
            }
            image = await AvatarLoader.shared.image(for: url)
        }
    }
}
