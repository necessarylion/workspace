import Foundation

/// Repairs the Markdown Bitbucket Cloud hands back, using the HTML it hands
/// back beside it.
///
/// Every comment and description arrives twice: as the Markdown the author
/// typed (`content.raw`) and as Bitbucket's own rendering of it
/// (`content.html`). The app draws the Markdown, because that is what the
/// preview understands — but the raw text writes a mention as
/// `@{712020:297e58ad-…}`, an account id and nothing else, so a comment reads
/// "Hello @{712020:297e58ad-1233-…}" instead of "Hello @Dale Chapman". The name
/// only exists in the HTML, so it is read off there and put back.
enum BitbucketMarkup {
    /// `markdown` with every `@{id}` replaced by the name the HTML gives that
    /// id. Ids the HTML does not name are left alone — a raw id reads badly, but
    /// silently dropping the mention would read as if nobody had been asked.
    static func resolvingMentions(in markdown: String, html: String?) -> String {
        guard markdown.contains("@{"), let html, !html.isEmpty else { return markdown }
        let names = mentionNames(in: html)
        guard !names.isEmpty else { return markdown }

        var result = markdown
        for (id, name) in names {
            result = result.replacingOccurrences(of: "@{\(id)}", with: escaped(name))
        }
        return result
    }

    /// Account id → the text Bitbucket drew for it, `@Dale Chapman`.
    ///
    /// The span is matched by its `data-atlassian-id`, not by its class: the
    /// class has changed name before, the attribute is what carries the id the
    /// raw text refers to.
    private static func mentionNames(in html: String) -> [String: String] {
        guard let pattern = try? NSRegularExpression(
            pattern: #"data-atlassian-id="([^"]+)"[^>]*>([^<]*)<"#
        ) else { return [:] }

        var names: [String: String] = [:]
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        for match in pattern.matches(in: html, range: range) {
            guard let id = Range(match.range(at: 1), in: html),
                  let name = Range(match.range(at: 2), in: html)
            else { continue }
            let text = decodingEntities(String(html[name])).trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            names[String(html[id])] = text.hasPrefix("@") ? text : "@\(text)"
        }
        return names
    }

    /// A name goes back into Markdown, so anything Markdown would read as
    /// formatting has to stop being that first — an underscore in a handle would
    /// otherwise start an italic run that never ends.
    private static func escaped(_ name: String) -> String {
        var result = ""
        for character in name {
            if "\\*_[]`".contains(character) { result.append("\\") }
            result.append(character)
        }
        return result
    }

    private static func decodingEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        return text
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&#x27;", with: "'")
            // Last: an escaped ampersand must not be turned back into one
            // before the entities it could be the start of are handled.
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}
