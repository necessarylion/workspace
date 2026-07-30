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
/// tall image cannot push the rest of a comment off the screen. That cap is why
/// clicking opens it at full size in a sheet: a wide screenshot of a diff is
/// unreadable at 420pt and there was nothing to do about it.
///
/// Opening the original is still on the context menu, and it is still the only
/// way to see one the app cannot fetch: a screenshot pasted into a Bitbucket
/// pull request is served from a private web address that only the reader's own
/// browser session opens.
@MainActor
struct MarkdownImage: View {
    let url: URL
    var alt: String = ""
    /// The width the document asked for, when it asked — a README writes its
    /// logo as `<img width="140">`, and a logo drawn at its full size instead
    /// is a banner. Nothing is said about the height: the picture keeps its
    /// shape, and the width is what decides how tall it comes out.
    var width: CGFloat?

    @State private var image: NSImage?
    @State private var isLoading = true
    @State private var isZoomed = false

    private static let maximumHeight: CGFloat = 420

    init(url: URL, alt: String = "", width: CGFloat? = nil) {
        self.url = url
        self.alt = alt
        self.width = width
        let cached = RemoteImageLoader.shared.cached(url)
        _image = State(initialValue: cached)
        _isLoading = State(initialValue: cached == nil && !RemoteImageLoader.shared.hasFailed(url))
    }

    var body: some View {
        content
            // The picture comes up through the placeholder it replaces rather
            // than taking its place between two frames. A comment with several
            // screenshots in it is otherwise read while it is still being hit
            // by them. The line of text moves as the picture takes its real
            // height, and that is not worth animating away: the reader is at
            // the top of a comment that is still arriving, and a height easing
            // open under them is worse than one that simply is.
            .animation(ViewerMotion.isReduced ? nil : .easeOut(duration: 0.2), value: image != nil)
            .animation(ViewerMotion.isReduced ? nil : .easeOut(duration: 0.2), value: isLoading)
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
                // A width the document asked for takes that ceiling's place,
                // and takes the height cap with it: the two together would
                // squeeze a tall picture narrower than it was asked to be.
                .frame(
                    maxWidth: width ?? image.size.width,
                    maxHeight: width == nil ? min(image.size.height, Self.maximumHeight) : nil
                )
                // Everything below hangs off the picture rather than off the
                // row it sits in, and the order is the whole of it: the
                // `maxWidth: .infinity` that pushes it left comes *last*. Put
                // it above these and the outline is drawn around the width of
                // the pane instead of around the picture — a bot's little
                // "Review Change Stack" badge in a box a thousand points wide —
                // and every click in that empty space opens the picture too.
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary, lineWidth: 1))
                .contentShape(RoundedRectangle(cornerRadius: 6))
                .accessibilityLabel(alt.isEmpty ? "Image" : alt)
                // `onTapGesture` is a pointer and nothing else: without these
                // the picture is announced as a picture and there is no way to
                // open it but a mouse.
                .accessibilityAddTraits(.isButton)
                .accessibilityHint("Opens this picture at full size")
                .accessibilityAction { isZoomed = true }
                // A wide screenshot in a pull request is capped at 420pt tall
                // and can only be squinted at, so a click opens it at its own
                // size rather than handing it to the browser. The browser is
                // still a menu away, and is still the only answer for one the
                // app could not fetch — see the placeholder below.
                .onTapGesture { isZoomed = true }
                .pointerCursor()
                .help("Click to see this at full size")
                .contextMenu {
                    Button(url.isFileURL ? "Open in Preview" : "Open in Browser") { open() }
                    Button("Copy Image") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.writeObjects([image])
                    }
                    if url.isFileURL {
                        Button("Show in Finder") { reveal() }
                    } else {
                        Button("Copy Image Address") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(url.absoluteString, forType: .string)
                        }
                    }
                }
                .sheet(isPresented: $isZoomed) {
                    ImageZoomSheet(image: image, title: alt.isEmpty ? url.lastPathComponent : alt) {
                        open()
                    }
                }
                // Left in the column, with the rest of the width left empty
                // rather than filled — and nothing drawn or clickable in it.
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.opacity)
        } else if isLoading {
            placeholder {
                ProgressView().controlSize(.small)
                Text(caption)
                    .foregroundStyle(.secondary)
            }
            .transition(.opacity)
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
            .transition(.opacity)
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

/// A picture at its own size, on top of everything, with the pane's worth of
/// room to look at it in.
///
/// It is a sheet rather than a window of its own: the app is one window, and a
/// screenshot in a pull request is read and dismissed rather than kept open
/// beside the conversation. `.fit` is where it opens — the whole picture,
/// whatever its shape — and `.actual` is the click that follows, which is what
/// a screenshot of code is opened for in the first place; at that size the
/// scroll view is what gets you around it.
private struct ImageZoomSheet: View {
    let image: NSImage
    let title: String
    /// Handing it to whatever owns the address, for the reader who wants it
    /// outside the app after all.
    let onOpenExternally: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var isActualSize = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(Int(image.size.width)) × \(Int(image.size.height))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer(minLength: 12)
                Button(isActualSize ? "Fit" : "Actual Size") { isActualSize.toggle() }
                    .pointerCursor()
                Button("Open") { onOpenExternally() }
                    .pointerCursor()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .pointerCursor()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.bar)
            Divider()

            // Both directions, because actual size is the point of the button
            // and a screenshot of a wide diff is wider than any sheet.
            ScrollView([.horizontal, .vertical]) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(
                        maxWidth: isActualSize ? image.size.width : nil,
                        maxHeight: isActualSize ? image.size.height : nil
                    )
                    .frame(
                        minWidth: isActualSize ? image.size.width : nil,
                        minHeight: isActualSize ? image.size.height : nil
                    )
                    .padding(isActualSize ? 0 : 16)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // Big enough to be worth opening, and short of the smallest screen the
        // app runs on.
        .frame(minWidth: 520, idealWidth: 900, minHeight: 380, idealHeight: 650)
        // ⎋ closes it, the way every other sheet in the app closes.
        .onExitCommand { dismiss() }
    }
}
