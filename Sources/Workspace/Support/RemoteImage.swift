import AppKit
import Observation
import SwiftUI

/// Loads the pictures Markdown points at, once each — downloaded when the
/// address is a web one, read off the disk when it is a file beside the document.
///
/// Same shape as `AvatarLoader`, and separate from it on purpose: an avatar is a
/// small square that is drawn hundreds of times, while these are full-size
/// screenshots drawn once — so they are counted and evicted by weight rather
/// than by number, and a failure is remembered rather than retried on every
/// redraw of the comment it sits in.
///
/// `@Observable` for `failed`: a placeholder has to redraw when its download
/// gives up.
@MainActor
@Observable
final class RemoteImageLoader {
    static let shared = RemoteImageLoader()

    @ObservationIgnored private let cache = NSCache<NSURL, NSImage>()
    private var failed: Set<URL> = []
    @ObservationIgnored private var inFlight: [URL: Task<NSImage?, Never>] = [:]

    private init() { cache.totalCostLimit = 64 * 1024 * 1024 }

    func cached(_ url: URL) -> NSImage? { cache.object(forKey: url as NSURL) }

    func hasFailed(_ url: URL) -> Bool { failed.contains(url) }

    /// The picture at `url`, downloading it the first time it is asked for.
    /// Concurrent callers share the one request.
    func image(for url: URL) async -> NSImage? {
        if let image = cached(url) { return image }
        if failed.contains(url) { return nil }
        if let task = inFlight[url] { return await task.value }

        let task = Task { [weak self] in
            let outcome = await Self.download(url)
            self?.finish(url, outcome: outcome)
            return outcome.image
        }
        inFlight[url] = task
        return await task.value
    }

    private func finish(_ url: URL, outcome: Outcome) {
        if let image = outcome.image {
            cache.setObject(image, forKey: url as NSURL, cost: outcome.bytes)
        } else {
            failed.insert(url)
        }
        inFlight[url] = nil
    }

    private struct Outcome {
        var image: NSImage?
        var bytes = 0
    }

    /// Nothing is sent but the request itself. The app has no sign-in of its own
    /// — every host it talks to is talked to through that host's own CLI — so a
    /// picture behind a login is one the reader opens in their browser, where
    /// they are already signed in.
    private static func download(_ url: URL) async -> Outcome {
        // A picture in a README is a file in the same checkout, and that one is
        // read rather than requested — no session, no cache policy, no waiting
        // on a network that has nothing to do with it.
        if url.isFileURL {
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                  let image = NSImage(data: data)
            else { return Outcome() }
            return Outcome(image: image, bytes: data.count)
        }

        var request = URLRequest(url: url)
        request.cachePolicy = .returnCacheDataElseLoad
        request.timeoutInterval = 30

        guard let (data, response) = try? await URLSession.shared.data(for: request) else {
            return Outcome()
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            return Outcome()
        }
        guard let image = NSImage(data: data) else { return Outcome() }
        return Outcome(image: image, bytes: data.count)
    }
}

/// A picture written into Markdown as `![alt](url)`.
///
/// It never grows past its own size — a small screenshot stays small rather than
/// being blown up to the width of the pane — and it is capped in height so one
/// tall image cannot push the rest of a comment off the screen. Clicking opens
/// the original, which is also the way to see one the app cannot fetch: a
/// screenshot pasted into a Bitbucket pull request is served from a private web
/// address that only the reader's own browser session opens.
@MainActor
struct MarkdownImage: View {
    let url: URL
    var alt: String = ""

    @State private var image: NSImage?
    @State private var isLoading = true

    private static let maximumHeight: CGFloat = 420

    init(url: URL, alt: String = "") {
        self.url = url
        self.alt = alt
        let cached = RemoteImageLoader.shared.cached(url)
        _image = State(initialValue: cached)
        _isLoading = State(initialValue: cached == nil && !RemoteImageLoader.shared.hasFailed(url))
    }

    var body: some View {
        content
            .task { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                // `maxWidth` alone would stretch a narrow picture across the
                // pane; the natural size is the ceiling, the pane the other one.
                .frame(maxWidth: image.size.width, maxHeight: min(image.size.height, Self.maximumHeight))
                .frame(maxWidth: .infinity, alignment: .leading)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary, lineWidth: 1))
                .accessibilityLabel(alt.isEmpty ? "Image" : alt)
                .onTapGesture { open() }
                .pointerCursor()
                .help(url.isFileURL ? "Open this file" : "Open in browser")
        } else if isLoading {
            placeholder {
                ProgressView().controlSize(.small)
                Text(caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            placeholder {
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let hint {
                        Text(hint)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer(minLength: 8)
                Button(url.isFileURL ? "Show in Finder" : "Open in Browser") { reveal() }
                    .buttonStyle(.link)
                    .pointerCursor()
            }
        }
    }

    /// Whatever the address points at, in the app that owns it — the browser for
    /// a web one, Preview or whatever else the reader set for a file.
    private func open() { NSWorkspace.shared.open(url) }

    /// The way out of a placeholder. A file that would not draw is one to look
    /// at rather than open, so Finder is where the button goes.
    private func reveal() {
        if url.isFileURL {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            open()
        }
    }

    /// Why it is a placeholder and not a picture. Only worth saying for a host
    /// the app is known not to be able to reach, or for a file that is there and
    /// still would not draw — anything else failed for a reason the reader can
    /// see for themselves by opening it.
    private var hint: String? {
        if url.isFileURL {
            return "This file is not a picture the app can draw."
        }
        guard let host = url.host()?.lowercased(),
              host == "bitbucket.org" || host.hasSuffix(".bitbucket.org")
        else { return nil }
        return "Bitbucket serves this one to your browser session only."
    }

    /// The alt text if the author wrote one, otherwise the file's own name —
    /// Bitbucket writes `![]` with nothing in it, and a bare "Image" says less
    /// than "Screenshot 2026-07-23 165108.png".
    private var caption: String {
        if !alt.isEmpty { return alt }
        let name = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
        return name.isEmpty ? url.absoluteString : name
    }

    private func placeholder<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 8, content: content)
            .font(.caption)
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary, lineWidth: 1))
    }

    private func load() async {
        if image != nil { return }
        image = await RemoteImageLoader.shared.image(for: url)
        isLoading = false
    }
}
