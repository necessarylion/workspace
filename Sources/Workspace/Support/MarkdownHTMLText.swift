import Foundation

/// The HTML half of the Markdown a host hands us.
///
/// GitHub and Bitbucket both render a comment as Markdown *with HTML in it*, and
/// a bot leans on that hard: CodeRabbit writes its whole review as nested
/// `<details>` sections, hides its bookkeeping in `<!-- … -->`, and reaches for
/// `<br>` inside table cells. None of that is Markdown, so the block parser used
/// to lay it out as literal angle brackets.
///
/// Nothing here is a real HTML parser — it is the handful of tags a comment
/// actually uses. Anything else is dropped rather than shown, which is what a
/// reader expects from a tag their viewer does not know.
enum MarkdownHTMLText {
    // MARK: - Comments

    /// The text with every `<!-- … -->` taken out, comments spanning lines
    /// included. A line that was nothing but a comment goes with it: leaving the
    /// empty line behind would open a gap where the reader sees no reason for one.
    ///
    /// Fenced code is left alone — a comment there is the point of the example.
    static func strippingComments(_ text: String) -> String {
        guard text.contains("<!--") else { return text }
        var result: [String] = []
        var inFence = false
        var inComment = false

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if !inComment, line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                inFence.toggle()
                result.append(line)
                continue
            }
            if inFence {
                result.append(line)
                continue
            }

            var kept = ""
            var index = line.startIndex
            while index < line.endIndex {
                if inComment {
                    guard let end = line.range(of: "-->", range: index..<line.endIndex) else {
                        index = line.endIndex
                        continue
                    }
                    inComment = false
                    index = end.upperBound
                } else if let start = line.range(of: "<!--", range: index..<line.endIndex) {
                    kept += line[index..<start.lowerBound]
                    inComment = true
                    index = start.upperBound
                } else {
                    kept += line[index..<line.endIndex]
                    index = line.endIndex
                }
            }

            // Only skip the line when the comment is what emptied it; a line that
            // was blank to begin with is the author's paragraph break.
            if kept.trimmingCharacters(in: .whitespaces).isEmpty, !line.isEmpty {
                continue
            }
            result.append(kept)
        }
        return result.joined(separator: "\n")
    }

    // MARK: - Containers

    /// A `<details>` or `<blockquote>` and the text either side of it. These two
    /// are the tags that hold *blocks*, so they cannot be flattened into a line
    /// the way an inline tag can — the parser has to recurse into them.
    struct Container {
        enum Tag { case details, blockquote }
        var tag: Tag
        /// `<details open>`, which GitHub shows already unfolded.
        var isOpen: Bool
        var before: Substring
        var inner: Substring
        var after: Substring
    }

    /// The first container in `text` that is not nested inside another one.
    ///
    /// Only tags of the same name are counted while looking for the close, so a
    /// `<blockquote>` inside a `<details>` — the shape every CodeRabbit review
    /// has — does not end the section early; the recursion picks it up from the
    /// inner text. A container that is never closed takes the rest of the text,
    /// which is the reading a browser gives it too.
    static func container(in text: String) -> Container? {
        guard text.contains("<") else { return nil }
        let fenced = fences(in: text)
        var index = text.startIndex
        var open: HTMLTag?
        var innerStart = text.startIndex
        var depth = 0

        while index < text.endIndex {
            if let fence = fenced.first(where: { $0.contains(index) }) {
                index = fence.upperBound
                continue
            }
            guard text[index] == "<", let tag = tag(at: index, in: text[...]) else {
                index = text.index(after: index)
                continue
            }
            defer { index = tag.range.upperBound }

            guard let found = open else {
                guard !tag.isClosing, tag.name == "details" || tag.name == "blockquote" else { continue }
                open = tag
                innerStart = tag.range.upperBound
                depth = 1
                continue
            }
            guard tag.name == found.name else { continue }
            if tag.isClosing {
                depth -= 1
                guard depth == 0 else { continue }
                return Container(
                    tag: found.name == "details" ? .details : .blockquote,
                    isOpen: found.attributes.contains("open"),
                    before: text[text.startIndex..<found.range.lowerBound],
                    inner: text[innerStart..<tag.range.lowerBound],
                    after: text[tag.range.upperBound...]
                )
            }
            depth += 1
        }

        guard let found = open else { return nil }
        return Container(
            tag: found.name == "details" ? .details : .blockquote,
            isOpen: found.attributes.contains("open"),
            before: text[text.startIndex..<found.range.lowerBound],
            inner: text[innerStart...],
            after: text[text.endIndex...]
        )
    }

    /// Lifts a `<summary>` out of a `<details>`, handing back its text and the
    /// rest of the section. The two are rarely on lines of their own —
    /// `<summary>…</summary><blockquote>` on one line is the usual shape — so
    /// what is left either side is stitched back together.
    static func summary(in text: Substring) -> (summary: String, body: String)? {
        var index = text.startIndex
        var opening: HTMLTag?
        while index < text.endIndex {
            guard text[index] == "<", let tag = tag(at: index, in: text) else {
                index = text.index(after: index)
                continue
            }
            index = tag.range.upperBound
            // A section of its own starts before this one ever said what it
            // was: the summary further down belongs to that one, not to us.
            if opening == nil, !tag.isClosing, tag.name == "details" { return nil }
            guard tag.name == "summary" else { continue }
            if let start = opening, tag.isClosing {
                return (
                    summary: String(text[start.range.upperBound..<tag.range.lowerBound]),
                    body: String(text[text.startIndex..<start.range.lowerBound]) + String(text[tag.range.upperBound...])
                )
            }
            if !tag.isClosing { opening = tag }
        }
        return nil
    }

    // MARK: - Inline

    /// One line of HTML rewritten as the Markdown that says the same thing, so
    /// the inline parser downstream needs to know nothing about tags. A tag with
    /// no Markdown spelling — `<div>`, `<span>`, a stray `<p>` — is dropped and
    /// its text kept.
    ///
    /// Backtick spans are stepped over untouched: `Array<String>` in a sentence
    /// is code, not an opening tag.
    static func markdown(from source: String) -> String {
        guard source.contains("<") || source.contains("&") else { return source }
        var result = ""
        var index = source.startIndex
        var inCode = false
        /// Addresses of the `<a>` tags still open, innermost last.
        var links: [String] = []

        while index < source.endIndex {
            let character = source[index]
            if character == "`" {
                inCode.toggle()
                result.append(character)
                index = source.index(after: index)
                continue
            }
            guard !inCode, character == "<", let tag = tag(at: index, in: source[...]) else {
                result.append(character)
                index = source.index(after: index)
                continue
            }
            result += markdown(for: tag, links: &links)
            index = tag.range.upperBound
        }
        return decoding(result)
    }

    private static func markdown(for tag: HTMLTag, links: inout [String]) -> String {
        switch tag.name {
        case "b", "strong": return "**"
        case "i", "em": return "*"
        case "del", "s", "strike": return "~~"
        // `kbd` has no Markdown of its own, and a key is read the way code is.
        case "code", "kbd", "tt", "samp": return "`"
        case "br": return "\n"
        case "hr": return "---"
        case "li": return tag.isClosing ? "" : "- "
        case "h1", "h2", "h3", "h4", "h5", "h6":
            guard !tag.isClosing, let level = Int(tag.name.dropFirst()) else { return "" }
            return String(repeating: "#", count: level) + " "
        case "img":
            guard !tag.isClosing, let address = attribute("src", in: tag.attributes) else { return "" }
            let image = "![\(attribute("alt", in: tag.attributes) ?? "")](\(address))"
            // A README sizes its logo with `width="140"`, and Markdown has no
            // way of saying that — so it is written as the attribute list
            // Bitbucket already hangs off an image, which is the one thing the
            // parser downstream reads after an address.
            guard let width = pixels(attribute("width", in: tag.attributes)) else { return image }
            return "\(image){: width=\(width) }"
        case "a":
            // The stack is pushed even for an `<a>` with no address, so the
            // closing tag always pops the one it belongs to.
            guard !tag.isClosing else {
                let address = links.popLast() ?? ""
                return address.isEmpty ? "" : "](\(address))"
            }
            let address = attribute("href", in: tag.attributes) ?? ""
            links.append(address)
            return address.isEmpty ? "" : "["
        default: return ""
        }
    }

    /// A length in points, out of what an attribute was set to: `140` and
    /// `140px` are the same number, and `50%` is nothing here — a share of the
    /// pane is not a size the preview can be told, and half of nothing is what
    /// it would come to.
    private static func pixels(_ value: String?) -> Int? {
        guard let value else { return nil }
        let digits = value.trimmingCharacters(in: .whitespaces).prefix { $0.isNumber }
        guard digits.count == value.trimmingCharacters(in: .whitespaces).count
                || value.trimmingCharacters(in: .whitespaces).lowercased().hasSuffix("px"),
              let number = Int(digits), number > 0
        else { return nil }
        return number
    }

    /// `href="…"` out of a tag's attribute text, quoted either way or bare.
    private static func attribute(_ name: String, in attributes: String) -> String? {
        guard let key = attributes.range(of: name + "=", options: .caseInsensitive) else { return nil }
        // Not a match when the name only ends another attribute — `data-src=`.
        if key.lowerBound > attributes.startIndex {
            let before = attributes[attributes.index(before: key.lowerBound)]
            guard before.isWhitespace else { return nil }
        }
        var value = attributes[key.upperBound...]
        if let quote = value.first, quote == "\"" || quote == "'" {
            value = value.dropFirst()
            guard let end = value.firstIndex(of: quote) else { return nil }
            return String(value[..<end])
        }
        return String(value.prefix { !$0.isWhitespace })
    }

    // MARK: - Entities

    /// `&amp;` and friends, including the numeric ones. Run after the tags are
    /// gone, so an escaped `&lt;div&gt;` becomes text rather than a tag.
    private static func decoding(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = ""
        var index = text.startIndex

        while index < text.endIndex {
            guard text[index] == "&",
                  let end = text[index...].prefix(12).firstIndex(of: ";"),
                  let character = entity(String(text[text.index(after: index)..<end]))
            else {
                result.append(text[index])
                index = text.index(after: index)
                continue
            }
            result += character
            index = text.index(after: end)
        }
        return result
    }

    private static func entity(_ name: String) -> String? {
        guard !name.isEmpty else { return nil }
        if name.hasPrefix("#") {
            let digits = name.dropFirst()
            let value: UInt32? = digits.hasPrefix("x") || digits.hasPrefix("X")
                ? UInt32(digits.dropFirst(), radix: 16)
                : UInt32(digits)
            guard let value, let scalar = Unicode.Scalar(value) else { return nil }
            return String(Character(scalar))
        }
        return named[name]
    }

    private static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
        "hellip": "…", "mdash": "—", "ndash": "–", "copy": "©", "reg": "®", "trade": "™",
        "times": "×", "check": "✓", "cross": "✗", "bull": "•", "middot": "·", "deg": "°",
        "rarr": "→", "larr": "←", "uarr": "↑", "darr": "↓", "laquo": "«", "raquo": "»",
        "ldquo": "\u{201C}", "rdquo": "\u{201D}", "lsquo": "\u{2018}", "rsquo": "\u{2019}",
    ]

    // MARK: - Tags

    struct HTMLTag {
        /// Lower-cased, so `<BR>` and `<br>` are the one tag.
        var name: String
        var isClosing: Bool
        var attributes: String
        var range: Range<String.Index>
    }

    /// The tag starting at `start`, or nothing when what follows the `<` is not
    /// one. A letter has to come first, which is what keeps `a <- b` and
    /// `x < 3` out of this.
    static func tag(at start: String.Index, in text: Substring) -> HTMLTag? {
        guard start < text.endIndex, text[start] == "<" else { return nil }
        var index = text.index(after: start)
        var isClosing = false
        if index < text.endIndex, text[index] == "/" {
            isClosing = true
            index = text.index(after: index)
        }
        guard index < text.endIndex, text[index].isLetter else { return nil }

        var name = ""
        while index < text.endIndex, text[index].isLetter || text[index].isNumber || text[index] == "-" {
            name.append(text[index])
            index = text.index(after: index)
        }

        // A `>` inside a quoted value does not end the tag.
        var attributes = ""
        var quote: Character?
        while index < text.endIndex {
            let character = text[index]
            if let open = quote {
                if character == open { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == ">" {
                return HTMLTag(
                    name: name.lowercased(),
                    isClosing: isClosing,
                    attributes: attributes,
                    range: start..<text.index(after: index)
                )
            }
            attributes.append(character)
            index = text.index(after: index)
        }
        return nil
    }

    /// The stretches of `text` inside ``` fences, which no tag is read out of.
    private static func fences(in text: String) -> [Range<String.Index>] {
        guard text.contains("```") else { return [] }
        var result: [Range<String.Index>] = []
        var start: String.Index?
        var index = text.startIndex

        while index < text.endIndex {
            let lineEnd = text[index...].firstIndex(of: "\n") ?? text.endIndex
            let next = lineEnd == text.endIndex ? text.endIndex : text.index(after: lineEnd)
            if text[index..<lineEnd].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if let open = start {
                    result.append(open..<next)
                    start = nil
                } else {
                    start = index
                }
            }
            index = next
        }
        // Still open at the end — the fence the author never closed.
        if let open = start { result.append(open..<text.endIndex) }
        return result
    }
}
