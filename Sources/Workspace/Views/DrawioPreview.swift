import SwiftUI

/// Full-pane view of a `.drawio` file, drawn by draw.io's own viewer — see
/// ``DiagramWebView`` for why that is a web view.
///
/// Unlike the mermaid fences in a Markdown page, this fills the viewer and
/// keeps its own scrolling: the diagram is fitted to the pane, and the toolbar
/// along the bottom carries the pages of a multi-page file, zoom and layers.
struct DrawioPreview: View {
    /// The file's text — the `<mxfile>` XML, compressed or not; the viewer
    /// unpacks it either way.
    let xml: String

    @State private var failure: String?

    var body: some View {
        if let failure {
            ContentUnavailableView(
                "Cannot draw this diagram",
                systemImage: "scribble.variable",
                description: Text(failure)
            )
        } else {
            DiagramWebView(
                page: "drawio-host",
                channel: "drawio",
                source: xml,
                draw: { xml in
                    DiagramWebView.script(
                        "showDiagram",
                        arguments: [xml, DiagramWebView.backgroundCSS]
                    )
                },
                onMessage: { message in
                    guard message["status"] as? String != "ok" else { return }
                    failure = message["message"] as? String
                        ?? "This file is not a draw.io diagram"
                }
            )
        }
    }
}
