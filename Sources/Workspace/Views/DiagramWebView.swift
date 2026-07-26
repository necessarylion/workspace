import AppKit
import SwiftUI
import WebKit

/// One of the diagram pages in `Resources/`, driven from Swift.
///
/// mermaid and draw.io are both JavaScript renderers with no native port worth
/// having, so both are drawn by the real thing in a `WKWebView` — and both are
/// driven the same way: load the page from the bundle as a file URL (which is
/// what lets it pull its library in with a plain relative `<script src>`), call
/// one function on it with the diagram's text, and listen for what it posts
/// back. Only the page, the call and what its messages mean differ.
///
/// The libraries are checked in rather than loaded from a CDN, so a diagram
/// draws the same offline and on every Mac — the same reason the themes travel
/// with the app.
struct DiagramWebView: NSViewRepresentable {
    /// The page in `Resources/`, without the `.html`.
    let page: String
    /// The name the page posts its messages under.
    let channel: String
    /// The diagram's own text. Changing it re-draws without reloading the page.
    let source: String
    /// The JS that draws the diagram, built by the caller: each page takes its
    /// own arguments. Use ``script(_:arguments:)`` to build the call.
    let draw: (String) -> String
    /// Whatever the page posted, `{ "status": … }` by convention.
    let onMessage: ([String: Any]) -> Void
    /// True for a diagram sitting in a wall of text: the page has nothing to
    /// scroll of its own, so the wheel belongs to the document behind it. False
    /// for one that fills the pane and pans and zooms on its own.
    var forwardsScrolling = false

    func makeCoordinator() -> Coordinator {
        Coordinator(onMessage: onMessage)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(context.coordinator, name: channel)
        context.coordinator.register(channel)
        let webView = forwardsScrolling
            ? PassThroughWebView(frame: .zero, configuration: configuration)
            : WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsMagnification = false
        // The page paints its own background, but the web view keeps drawing
        // one of its own around and under it — this is what stops a white edge
        // showing through while the diagram is still being drawn.
        webView.underPageBackgroundColor = AppColors.viewerBackground
        context.coordinator.webView = webView

        guard let host = Bundle.module.url(forResource: page, withExtension: "html") else {
            onMessage(["status": "error", "message": "Diagram support is missing from this build"])
            return webView
        }
        webView.loadFileURL(host, allowingReadAccessTo: host.deletingLastPathComponent())
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.onMessage = onMessage
        context.coordinator.draw(source, using: draw)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        // The content controller holds the coordinator strongly; without this
        // every diagram ever opened stays alive.
        for channel in coordinator.channels {
            webView.configuration.userContentController.removeScriptMessageHandler(forName: channel)
        }
    }

    /// `name(arg, arg, …)` with every argument as a JS string literal — quotes,
    /// newlines and all.
    static func script(_ function: String, arguments: [String]) -> String {
        let literals = arguments.map { value -> String in
            let data = try? JSONSerialization.data(withJSONObject: [value])
            guard let data, let array = String(data: data, encoding: .utf8) else { return "\"\"" }
            return String(array.dropFirst().dropLast())
        }
        return "\(function)(\(literals.joined(separator: ",")))"
    }

    /// The pane's own colour, for the page to paint itself in, so the diagram
    /// sits on the same shade as everything around it.
    static let backgroundCSS: String = {
        guard let color = AppColors.viewerBackground.usingColorSpace(.sRGB) else { return "#000000" }
        return String(
            format: "#%02X%02X%02X",
            Int(color.redComponent * 255),
            Int(color.greenComponent * 255),
            Int(color.blueComponent * 255)
        )
    }()

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var onMessage: ([String: Any]) -> Void
        weak var webView: WKWebView?
        /// Every channel this coordinator was registered under, so all of them
        /// can be taken off the content controller when the view goes away.
        private(set) var channels: Set<String> = []

        private var isLoaded = false
        private var drawn: String?
        private var pending: (() -> Void)?

        init(onMessage: @escaping ([String: Any]) -> Void) {
            self.onMessage = onMessage
        }

        func register(_ channel: String) {
            channels.insert(channel)
        }

        /// Called on every SwiftUI update, so it does nothing unless the
        /// diagram's text actually changed. Before the page has loaded the call
        /// is kept and made from `didFinish`.
        func draw(_ source: String, using script: (String) -> String) {
            guard source != drawn else { return }
            drawn = source
            let javaScript = script(source)
            guard isLoaded else {
                pending = { [weak self] in self?.webView?.evaluateJavaScript(javaScript) }
                return
            }
            webView?.evaluateJavaScript(javaScript)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isLoaded = true
            pending?()
            pending = nil
        }

        func webView(
            _ webView: WKWebView,
            didFail navigation: WKNavigation!,
            withError error: Error
        ) {
            onMessage(["status": "error", "message": error.localizedDescription])
        }

        /// The page is ours and never navigates; a link inside a diagram is the
        /// one thing that would try, and that belongs in a browser.
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard navigationAction.navigationType == .other,
                  navigationAction.request.url?.isFileURL == true
            else {
                if let url = navigationAction.request.url, !url.isFileURL {
                    NSWorkspace.shared.open(url)
                }
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        func userContentController(
            _ controller: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard let payload = message.body as? [String: Any] else { return }
            onMessage(payload)
        }
    }
}

/// A web view whose page has nothing to scroll, so the wheel is meant for the
/// document it sits in.
private final class PassThroughWebView: WKWebView {
    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }
}
