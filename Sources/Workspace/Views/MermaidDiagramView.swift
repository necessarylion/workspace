import AppKit
import SwiftUI

/// A ```` ```mermaid ```` fence in the Markdown preview, drawn as a diagram by
/// mermaid itself — see ``DiagramWebView`` for why that is a web view.
///
/// The page has no scrollers: it reports the height of what it drew and the
/// view is sized to it, so the diagram sits in the Markdown column like any
/// other block.
struct MermaidDiagram: View {
    let source: String

    /// Nothing is shown until the first measurement arrives; a web view given
    /// an arbitrary starting height would push the text below it around when
    /// the real one lands.
    @State private var height: CGFloat = 0
    @State private var failure: String?

    var body: some View {
        if let failure {
            // Mermaid the user is still typing is mermaid that does not parse.
            // Falling back to the fence's own text keeps the content readable
            // and says what mermaid objected to.
            VStack(alignment: .leading, spacing: 6) {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(source)
                    .font(.system(.callout, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(10)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary, lineWidth: 1))
        } else {
            DiagramWebView(
                page: "mermaid-host",
                channel: "mermaid",
                source: source,
                draw: { source in
                    DiagramWebView.script(
                        "renderDiagram",
                        arguments: [
                            source,
                            DiagramWebView.backgroundCSS,
                            Self.fontFamilyCSS,
                            "\(Int(MarkdownText.bodySize))px"
                        ]
                    )
                },
                onMessage: { message in
                    switch message["status"] as? String {
                    case "ok", "resize":
                        if let value = message["height"] as? Double, value > 0 {
                            height = value
                        }
                    default:
                        failure = message["message"] as? String
                            ?? "This diagram could not be drawn"
                    }
                },
                forwardsScrolling: true
            )
            .frame(height: max(height, 1))
            .opacity(height > 0 ? 1 : 0)
        }
    }

    /// Labels in a diagram are prose, so they take the interface font — not the
    /// code font the fence was written in.
    private static let fontFamilyCSS =
        "-apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Helvetica Neue', sans-serif"
}
