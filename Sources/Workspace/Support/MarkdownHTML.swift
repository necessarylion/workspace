import AppKit
import Foundation

/// The Markdown document as a printable HTML page, block for block the same as
/// `MarkdownText` draws on screen — only lighter, because this is what goes into
/// the PDF. Nothing here is loaded from the network: the one script the page can
/// pull in is the checked-in copy of mermaid, put beside it by `MarkdownPDF`,
/// and a picture is written in as the bytes the preview already downloaded.
@MainActor
enum MarkdownHTML {
    /// `margin` is the gap the sheets are printed with: the page keeps it left
    /// and right itself, and `prepare` leaves room for it above and below.
    static func page(
        title: String,
        blocks: [MarkdownText.Block],
        margin: CGFloat,
        includesDiagrams: Bool
    ) -> String {
        let body = blocks.map(html(for:)).joined(separator: "\n")
        return """
        <!doctype html>
        <html>
          <head>
            <meta charset="utf-8" />
            <title>\(escape(title))</title>
            <style>\(styles(margin: margin))</style>
            \(includesDiagrams ? "<script src=\"mermaid.min.js\"></script>" : "")
          </head>
          <body>
        \(body)
        \(script)
          </body>
        </html>
        """
    }

    // MARK: - Blocks

    private static func html(for block: MarkdownText.Block) -> String {
        switch block {
        case .heading(let level, let text):
            return "<h\(level)>\(inline(text))</h\(level)>"
        case .paragraph(let text):
            return "<p>\(inline(text))</p>"
        case .bullet(let indent, let text):
            return item(marker: indent > 0 ? "◦" : "•", text: inline(text), indent: indent)
        case .numbered(let indent, let number, let text):
            return item(marker: "\(escape(number)).", text: inline(text), indent: indent)
        case .task(let done, let text):
            return item(marker: done ? "☑" : "☐", text: inline(text), indent: 0)
        case .quote(let alert, let blocks):
            let head = alert.map { "<p class=\"alert\">\(escape($0.title))</p>" } ?? ""
            return "<blockquote>\(head)\(blocks.map(html(for:)).joined(separator: "\n"))</blockquote>"
        case .disclosure(let summary, _, let blocks):
            // Always unfolded: a sheet of paper has nothing to click.
            return """
            <div class="details">
              <p class="summary">\(inline(summary))</p>
              \(blocks.map(html(for:)).joined(separator: "\n"))
            </div>
            """
        case .code(_, let text):
            // Plain, whatever the fence named: the preview's colours come from
            // the editor theme, which is dark, and dark syntax on a white page
            // reads worse than no colour at all.
            return "<pre><code>\(escape(text))</code></pre>"
        case .mermaid(let source):
            // The source, and nothing else — the script below swaps in the
            // drawn diagram once mermaid has had it.
            return "<div class=\"diagram\">\(escape(source))</div>"
        case .image(let address, let alt):
            // The page is rendered off-line, in a web view with no sign-in of
            // its own, so the picture cannot be fetched here — it goes in as the
            // bytes the app already has. One it never loaded is named instead of
            // being left as a hole in the page.
            guard let inlined = dataURI(for: address) else {
                let name = alt.isEmpty ? address : alt
                return "<p class=\"missing\">\(escape(name))</p>"
            }
            return "<p class=\"picture\"><img src=\"\(inlined)\" alt=\"\(escape(alt))\" /></p>"
        case .table(let headers, let rows):
            let head = headers.map { "<th>\(inline($0))</th>" }.joined()
            let body = rows.map { row in
                "<tr>" + row.map { "<td>\(inline($0))</td>" }.joined() + "</tr>"
            }.joined(separator: "\n")
            return """
            <table>
              <thead><tr>\(head)</tr></thead>
              <tbody>\(body)</tbody>
            </table>
            """
        case .rule:
            return "<hr />"
        case .spacer:
            // Blank lines are what separates the blocks, and the spacing is in
            // the stylesheet.
            return ""
        }
    }

    /// The picture at `address` as a `data:` URI, or nothing when the preview
    /// never managed to load it — a private Bitbucket attachment with no account
    /// behind it, most often.
    private static func dataURI(for address: String) -> String? {
        guard let url = URL(string: address),
              // A file beside the document is read here and now — the export can
              // be asked for from the source view, where the preview that would
              // have loaded it was never on screen.
              let image = RemoteImageLoader.shared.cached(url)
                  ?? (url.isFileURL ? NSImage(contentsOf: url) : nil),
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:])
        else { return nil }
        return "data:image/png;base64,\(png.base64EncodedString())"
    }

    /// A list row: the marker in a column of its own, so a wrapped line lines up
    /// under the text rather than under the bullet.
    private static func item(marker: String, text: String, indent: Int) -> String {
        let inset = indent * 18
        return """
        <div class="item" style="margin-left: \(inset)px"><span class="marker">\(marker)</span><span>\(text)</span></div>
        """
    }

    // MARK: - Inline

    /// Bold, italic, `code`, strikethrough and links, read off the same
    /// `AttributedString` parse the preview uses.
    private static func inline(_ source: String) -> String {
        let parsed = (try? AttributedString(
            markdown: source,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(source)

        var result = ""
        for run in parsed.runs {
            var piece = escape(String(parsed[run.range].characters))
            let intent = run.inlinePresentationIntent ?? []
            if intent.contains(.code) { piece = "<code>\(piece)</code>" }
            if intent.contains(.stronglyEmphasized) { piece = "<strong>\(piece)</strong>" }
            if intent.contains(.emphasized) { piece = "<em>\(piece)</em>" }
            if intent.contains(.strikethrough) { piece = "<del>\(piece)</del>" }
            // A link is dead on paper, so it keeps its styling and carries the
            // address for whoever opens the PDF on a screen.
            if let link = run.link {
                piece = "<a href=\"\(escape(link.absoluteString))\">\(piece)</a>"
            }
            result += piece
        }
        return result
    }

    private static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    // MARK: - Page

    /// A document to be printed: white paper, dark text, and the sheet's side
    /// margins as the page's own padding.
    private static func styles(margin: CGFloat) -> String {
    """
    :root { color-scheme: light; }
    body {
      margin: 0;
      padding: 0 \(Int(margin))px;
      background: #ffffff;
      color: #1c1c1e;
      font: 11pt/1.55 -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", sans-serif;
      -webkit-print-color-adjust: exact;
      print-color-adjust: exact;
    }
    p, .item, blockquote, pre, table, .diagram { margin: 0 0 8pt 0; }
    h1, h2, h3, h4, h5, h6 {
      margin: 16pt 0 6pt 0;
      line-height: 1.25;
    }
    h1 { font-size: 22pt; } h2 { font-size: 17pt; } h3 { font-size: 14pt; }
    h4, h5, h6 { font-size: 11.5pt; }
    a { color: #0a58ca; }
    code {
      font-family: ui-monospace, "SF Mono", Menlo, monospace;
      font-size: 0.9em;
      background: rgba(0, 0, 0, 0.06);
      border-radius: 3px;
      padding: 1px 4px;
    }
    pre {
      background: #f6f6f8;
      border: 1px solid #e2e2e6;
      border-radius: 5px;
      padding: 8pt 10pt;
      overflow: hidden;
      white-space: pre-wrap;
      word-break: break-word;
      break-inside: avoid;
      page-break-inside: avoid;
    }
    pre code { background: none; padding: 0; font-size: 9.5pt; }
    blockquote {
      border-left: 3px solid #d0d0d5;
      padding-left: 10pt;
      color: #55555c;
    }
    blockquote > :last-child { margin-bottom: 0; }
    .alert { font-weight: 600; color: #3c3c43; }
    .details { margin: 0 0 8pt 0; padding-left: 10pt; border-left: 1px solid #e2e2e6; }
    .details .summary { font-weight: 600; margin-bottom: 5pt; }
    .details > :last-child { margin-bottom: 0; }
    .item { display: flex; gap: 7px; align-items: baseline; }
    .item .marker { color: #77777f; flex: none; }
    hr { border: none; border-top: 1px solid #e2e2e6; margin: 12pt 0; }
    table {
      border-collapse: collapse;
      width: 100%;
      break-inside: avoid;
      page-break-inside: avoid;
    }
    th, td {
      border: 1px solid #e2e2e6;
      padding: 4pt 7pt;
      text-align: left;
      vertical-align: top;
    }
    th { background: #f2f2f5; font-weight: 600; }
    tbody tr:nth-child(even) { background: #fafafc; }
    .diagram { text-align: center; }
    .diagram svg { max-width: 100%; height: auto; }
    .picture img {
      max-width: 100%;
      height: auto;
      border: 1px solid #e2e2e6;
      border-radius: 5px;
    }
    .missing { color: #77777f; font-style: italic; }
    """
    }

    /// `prepare(usable)` draws the diagrams, then hands back the height of the
    /// document and every y it may be cut at — one per sheet. `MarkdownPDF`
    /// calls it and renders the stretches between those cuts.
    ///
    /// There is no CSS for any of this: `break-inside` and friends only mean
    /// something to a printer, and this document is never printed — it is
    /// measured, rendered in stretches, and assembled.
    private static let script = """
    <script>
      async function prepare(usable) {
        await drawDiagrams(usable);
        await document.fonts.ready;

        // Where a cut would not run through anything: the top and bottom of
        // every block, plus — inside a block too tall to be moved to the next
        // sheet — the bottom of each of its lines and of anything nested in it,
        // so a long paragraph or code block is cut between its rows of text.
        const stops = [0];
        const nodes = Array.from(document.body.children).filter((n) => n.tagName !== "SCRIPT");
        for (const node of nodes) {
          const box = node.getBoundingClientRect();
          if (box.height === 0) continue;
          const top = box.top + window.scrollY;
          stops.push(top, top + box.height);
          if (box.height <= usable) continue;
          const range = document.createRange();
          range.selectNodeContents(node);
          for (const line of range.getClientRects()) stops.push(line.bottom + window.scrollY);
          for (const child of node.querySelectorAll("*")) {
            const rect = child.getBoundingClientRect();
            if (rect.height > 0) stops.push(rect.bottom + window.scrollY);
          }
        }
        stops.sort((a, b) => a - b);

        const total = document.body.scrollHeight;
        const cuts = [0];
        let start = 0;
        // The guard is for a document that somehow stops making progress; a
        // real one runs out of height long before.
        while (start + usable < total && cuts.length < 500) {
          const limit = start + usable;
          let next = 0;
          for (const stop of stops) {
            if (stop > start + 1 && stop <= limit && stop > next) next = stop;
          }
          // Nothing in this stretch can be cut — a diagram taller than the
          // sheet, say. Cut at the margin and carry on.
          if (!next) next = limit;
          cuts.push(next);
          start = next;
        }
        return { total: total, cuts: cuts };
      }

      // Whatever mermaid refuses is left as the text of the fence, the way the
      // preview leaves it.
      async function drawDiagrams(usable) {
        const blocks = Array.from(document.querySelectorAll(".diagram"));
        if (!blocks.length || typeof mermaid === "undefined") return;
        // Light theme here, unlike the preview: this goes on paper.
        mermaid.initialize({
          startOnLoad: false,
          theme: "default",
          securityLevel: "strict",
          fontFamily: "-apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Helvetica Neue', sans-serif"
        });
        for (let index = 0; index < blocks.length; index += 1) {
          const block = blocks[index];
          const source = block.textContent;
          try {
            const { svg } = await mermaid.render("diagram-" + index, source);
            block.innerHTML = svg;
            // A diagram taller than the sheet would be cut in half; scaled to
            // fit, it stays one picture.
            const drawn = block.querySelector("svg");
            if (drawn) {
              drawn.style.maxHeight = usable + "px";
              drawn.style.width = "auto";
              drawn.style.height = "auto";
            }
          } catch (error) {
            const fallback = document.createElement("pre");
            fallback.textContent = source;
            block.innerHTML = "";
            block.appendChild(fallback);
          } finally {
            // mermaid measures in a scratch element it appends to the body; a
            // failed render leaves it behind, and it would be printed.
            document.querySelectorAll("#ddiagram-" + index).forEach((node) => node.remove());
          }
        }
      }
    </script>
    """
}
