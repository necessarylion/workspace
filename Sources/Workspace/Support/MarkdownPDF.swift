import AppKit
import UniformTypeIdentifiers
import WebKit

/// Writes the Markdown preview out as a PDF.
///
/// The page on screen is SwiftUI, and SwiftUI cannot paginate: `ImageRenderer`
/// draws one endless strip, and a `WKWebView` — which is what a ```` ```mermaid ````
/// fence is drawn in — comes out of it as a blank rectangle. So the document is
/// written a second time as HTML and rendered by WebKit.
///
/// WebKit's own `NSPrintOperation` is not used either: on a plain document it
/// paginates without end, filling the file with pages until the disk gives out.
/// Instead the page says where it may be cut — between blocks, and between the
/// lines of a block too tall to move whole — and each stretch is rendered on its
/// own and laid on a sheet here. Nothing is ever cut through a line of text.
///
/// The blocks come from `MarkdownText.blocks(in:)`, the same parse the preview
/// walks, so the file cannot say something different from the screen. Only the
/// paint differs: the PDF is a light document, because it is made to be printed
/// and mailed rather than read in a dark viewer.
@MainActor
enum MarkdownPDF {
    /// Asks where to save, writes the PDF there, then reports back. `onFinish`
    /// is not called at all when the reader cancels the save panel.
    static func save(
        markdown: String,
        suggestedName: String,
        onFinish: @escaping (Result<URL, Error>) -> Void
    ) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = "\(suggestedName).pdf"
        panel.canCreateDirectories = true
        panel.title = "Save as PDF"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        write(markdown: markdown, title: suggestedName, to: url, onFinish: onFinish)
    }

    /// Writes the PDF without asking — the save panel's other half, and the way
    /// in for anything that already knows where the file goes.
    static func write(
        markdown: String,
        title: String,
        to url: URL,
        onFinish: @escaping (Result<URL, Error>) -> Void
    ) {
        do {
            let renderer = try Renderer(markdown: markdown, title: title, destination: url)
            renderer.start(onFinish: onFinish)
        } catch {
            onFinish(.failure(error))
        }
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}

// MARK: - Rendering

/// One export: an off-screen web view, the page it loads, and the sheets cut
/// out of it.
@MainActor
private final class Renderer: NSObject, WKNavigationDelegate {
    /// The exports still in flight. A renderer is only referenced by its own
    /// callbacks, so without this it would be released the moment `start`
    /// returns and the page would never finish loading.
    private static var running: [Renderer] = []

    /// Room to breathe around the text, in points. The page leaves the same gap
    /// left and right as padding of its own; top and bottom are kept here, by
    /// where each stretch is laid on its sheet.
    private static let margin: CGFloat = 48
    /// A diagram-heavy document is the slow case. Past this, the export is
    /// given up on rather than left hanging with no file and no word of why.
    private static let timeout: TimeInterval = 30

    private let title: String
    private let destination: URL
    private let workDirectory: URL
    private let pageURL: URL
    /// The reader's own paper — A4 or US Letter, whichever they print on.
    private let paper: NSSize
    private let webView: WKWebView
    /// The web view has to be in a window to lay out; this one is never ordered
    /// in, so nothing appears on screen.
    private let window: NSWindow
    private var onFinish: ((Result<URL, Error>) -> Void)?

    init(markdown: String, title: String, destination: URL) throws {
        self.title = title
        self.destination = destination

        let blocks = MarkdownText.blocks(in: markdown)
        let needsDiagrams = blocks.contains { if case .mermaid = $0 { true } else { false } }

        // WebKit only reads local files out of a directory it was handed, and
        // the app bundle is not writable, so the page is assembled in a scratch
        // directory next to a copy of the mermaid script it pulls in.
        workDirectory = FileManager.default.temporaryDirectory
            .appending(path: "markdown-pdf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)

        if needsDiagrams {
            guard let script = Bundle.module.url(forResource: "mermaid.min", withExtension: "js") else {
                throw MarkdownPDF.Failure(message: "Diagram support is missing from this build")
            }
            try FileManager.default.copyItem(at: script, to: workDirectory.appending(path: "mermaid.min.js"))
        }

        paper = NSPrintInfo.shared.paperSize
        let page = MarkdownHTML.page(
            title: title,
            blocks: blocks,
            margin: Self.margin,
            includesDiagrams: needsDiagrams
        )
        pageURL = workDirectory.appending(path: "document.html")
        try page.write(to: pageURL, atomically: true, encoding: .utf8)

        // Laid out at the width it will be printed at, so a line wraps in the
        // file exactly where the measurements said it would.
        webView = WKWebView(frame: NSRect(origin: .zero, size: paper), configuration: WKWebViewConfiguration())
        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: paper),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = webView

        super.init()
        webView.navigationDelegate = self
    }

    /// Loading only starts here, not in `init`, so there is somewhere to report
    /// to by the time the page is up.
    func start(onFinish: @escaping (Result<URL, Error>) -> Void) {
        self.onFinish = onFinish
        Self.running.append(self)
        webView.loadFileURL(pageURL, allowingReadAccessTo: workDirectory)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.timeout) { [weak self] in
            self?.finish(.failure(MarkdownPDF.Failure(message: "The document took too long to draw")))
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { await render() }
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        finish(.failure(error))
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        finish(.failure(error))
    }

    /// Draw the diagrams, ask where the document may be cut, then render one
    /// stretch per sheet.
    private func render() async {
        guard onFinish != nil else { return }
        let usable = paper.height - Self.margin * 2
        do {
            let measurements = try await webView.callAsyncJavaScript(
                "return await prepare(\(usable));",
                contentWorld: .page
            )
            guard let payload = measurements as? [String: Any],
                  let cuts = payload["cuts"] as? [Double],
                  let total = payload["total"] as? Double
            else {
                throw MarkdownPDF.Failure(message: "The document could not be measured")
            }

            var sheets: [Data] = []
            for (index, cut) in cuts.enumerated() {
                let bottom = index + 1 < cuts.count ? cuts[index + 1] : total
                let configuration = WKPDFConfiguration()
                configuration.rect = CGRect(
                    x: 0,
                    y: cut,
                    width: paper.width,
                    height: max(bottom - cut, 1)
                )
                sheets.append(try await webView.pdf(configuration: configuration))
            }
            try compose(sheets)
            finish(.success(destination))
        } catch {
            finish(.failure(error))
        }
    }

    /// Each stretch is its own one-page PDF as wide as the paper and only as
    /// tall as its content; this lays them on full sheets, one apiece, hanging
    /// from the top margin.
    private func compose(_ sheets: [Data]) throws {
        var mediaBox = CGRect(origin: .zero, size: paper)
        let info: [CFString: Any] = [kCGPDFContextTitle: title]
        guard let context = CGContext(destination as CFURL, mediaBox: &mediaBox, info as CFDictionary) else {
            throw MarkdownPDF.Failure(message: "Could not write to \(destination.lastPathComponent)")
        }
        for sheet in sheets {
            guard let provider = CGDataProvider(data: sheet as CFData),
                  let document = CGPDFDocument(provider),
                  let page = document.page(at: 1)
            else { continue }
            let box = page.getBoxRect(.mediaBox)
            context.beginPDFPage(nil)
            context.saveGState()
            // Nothing may spill past the sheet, whatever the stretch measured.
            context.clip(to: mediaBox)
            // PDF coordinates run up from the bottom of the sheet, so a stretch
            // hangs from the top margin by being lifted its own height.
            context.translateBy(x: 0, y: paper.height - Self.margin - box.height)
            context.drawPDFPage(page)
            context.restoreGState()
            context.endPDFPage()
        }
        context.closePDF()
    }

    private func finish(_ result: Result<URL, Error>) {
        guard let onFinish else { return }
        self.onFinish = nil
        window.contentView = nil
        try? FileManager.default.removeItem(at: workDirectory)
        Self.running.removeAll { $0 === self }
        onFinish(result)
    }
}
