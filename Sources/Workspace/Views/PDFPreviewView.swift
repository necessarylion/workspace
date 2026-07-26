import AppKit
import PDFKit
import SwiftUI

/// A `.pdf` file in the viewer.
///
/// PDFKit already knows how to paginate, scroll and search a document, so this
/// is a thin wrapper around `PDFView` rather than a renderer of its own — the
/// same bargain the terminal makes with libghostty. What the wrapper adds is a
/// floating bar: the window has no toolbar to hang page and zoom controls off,
/// and `PDFView` ships none of its own.
struct PDFPreview: View {
    let url: URL

    /// One controller per file. The bar and the keyboard both drive the same
    /// `PDFView`, so somebody outside the representable has to hold it.
    @State private var controller = PDFPreviewController()

    var body: some View {
        Group {
            if controller.isLoaded {
                PDFKitView(controller: controller)
                    .overlay(alignment: .bottom) { toolbar }
            } else {
                ContentUnavailableView(
                    "Could not open this PDF",
                    systemImage: "doc.richtext",
                    description: Text("The file is damaged, encrypted, or not a PDF.")
                )
            }
        }
        // A file can be replaced under the viewer — the same URL then means a
        // different document — so loading is keyed on the URL, not on first
        // appearance only.
        .onAppear { controller.load(url) }
        .onChange(of: url) { _, new in controller.load(new) }
    }

    /// Page and zoom, floating over the document. It stays out of the way of
    /// the page itself, which is why it sits at the bottom edge rather than in
    /// a row of its own: a PDF is read full height.
    private var toolbar: some View {
        HStack(spacing: 10) {
            Button {
                controller.goToPreviousPage()
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(!controller.canGoToPreviousPage)
            .help("Previous page")
            .pointerCursor(controller.canGoToPreviousPage)

            Text("\(controller.currentPage) / \(controller.pageCount)")
                .font(.caption.monospacedDigit())
                .frame(minWidth: 54)

            Button {
                controller.goToNextPage()
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(!controller.canGoToNextPage)
            .help("Next page")
            .pointerCursor(controller.canGoToNextPage)

            Divider().frame(height: 14)

            Button {
                controller.zoomOut()
            } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .help("Zoom out")
            .pointerCursor()

            Button {
                controller.fitWidth()
            } label: {
                Text("\(Int((controller.zoom * 100).rounded()))%")
                    .font(.caption.monospacedDigit())
                    .frame(minWidth: 38)
            }
            .help("Fit the page to the window")
            .pointerCursor()

            Button {
                controller.zoomIn()
            } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .help("Zoom in")
            .pointerCursor()
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(.quaternary, lineWidth: 1))
        .padding(.bottom, 14)
    }
}

// MARK: - Controller

/// Owns the `PDFView` and answers for it: what page is showing, how far it is
/// zoomed, and the handful of commands the bar sends back down.
@MainActor
@Observable
final class PDFPreviewController {
    /// Kept here rather than made in `makeNSView`, so the bar can talk to it
    /// and so scroll position survives a SwiftUI update.
    @ObservationIgnored let view = PDFView()

    private(set) var isLoaded = false
    private(set) var pageCount = 0
    private(set) var currentPage = 1
    private(set) var zoom: CGFloat = 1

    /// The URL currently in the view, so an unchanged file is not reloaded —
    /// reloading would throw away where the reader had scrolled to.
    private var loadedURL: URL?
    @ObservationIgnored private let observers = ObserverTokens()

    var canGoToPreviousPage: Bool { currentPage > 1 }
    var canGoToNextPage: Bool { currentPage < pageCount }

    init() {
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = AppColors.viewerBackground

        let center = NotificationCenter.default
        for name in [Notification.Name.PDFViewPageChanged, .PDFViewScaleChanged] {
            observers.tokens.append(
                center.addObserver(forName: name, object: view, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.readState() }
                }
            )
        }
    }

    func load(_ url: URL) {
        guard loadedURL != url else { return }
        loadedURL = url
        guard let document = PDFDocument(url: url) else {
            view.document = nil
            isLoaded = false
            pageCount = 0
            return
        }
        view.document = document
        isLoaded = true
        pageCount = document.pageCount
        readState()
    }

    func goToPreviousPage() { view.goToPreviousPage(nil) }
    func goToNextPage() { view.goToNextPage(nil) }

    func zoomIn() { setScale(view.scaleFactor * 1.25) }
    func zoomOut() { setScale(view.scaleFactor / 1.25) }

    /// Back to the scale PDFKit picked for the window. `autoScales` is turned
    /// off by any manual zoom, so it has to be turned back on here — otherwise
    /// the page stops following the window as it is resized.
    func fitWidth() {
        view.autoScales = true
        view.scaleFactor = view.scaleFactorForSizeToFit
        readState()
    }

    private func setScale(_ scale: CGFloat) {
        view.autoScales = false
        view.scaleFactor = min(max(scale, 0.25), 8)
        readState()
    }

    /// Pulls what the bar shows out of the view. Called on every page and scale
    /// notification, which is how scrolling and pinch-zoom keep it honest.
    private func readState() {
        guard let document = view.document else { return }
        pageCount = document.pageCount
        if let page = view.currentPage {
            currentPage = document.index(for: page) + 1
        }
        // Shown as a percentage of "fits the window", not of the page's own
        // point size: a reader zooms relative to what they can see.
        let fit = view.scaleFactorForSizeToFit
        zoom = fit > 0 ? view.scaleFactor / fit : view.scaleFactor
    }
}

/// The notification tokens, kept in a box of their own: a `deinit` on a
/// main-actor class runs outside that actor and so cannot reach its stored
/// properties, but this box's own `deinit` can reach these.
private final class ObserverTokens: @unchecked Sendable {
    var tokens: [NSObjectProtocol] = []

    deinit {
        for token in tokens { NotificationCenter.default.removeObserver(token) }
    }
}

// MARK: - The PDFKit view

private struct PDFKitView: NSViewRepresentable {
    let controller: PDFPreviewController

    func makeNSView(context: Context) -> PDFView { controller.view }

    func updateNSView(_ view: PDFView, context: Context) {}
}
