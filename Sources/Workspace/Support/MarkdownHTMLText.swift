import Foundation

/// The HTML half of the Markdown a host hands us.
///
/// GitHub and Bitbucket both render a comment as Markdown *with HTML in it*, and
/// a bot leans on that hard: CodeRabbit writes its whole review as nested
/// `<details>` sections, hides its bookkeeping in `<!-- … -->`, and reaches for
/// `<br>` inside table cells. None of that is Markdown, so cmark hands it over
/// untouched — an `HTMLBlock` with the literal string in it, or an `InlineHTML`
/// in the middle of a paragraph — and this is what reads it.
///
/// Nothing here is a real HTML parser — it is the handful of tags a comment
/// actually uses. Anything else is dropped rather than shown, which is what a
/// reader expects from a tag their viewer does not know.
///
/// The shape of the job changed when `MarkdownParser` took over the document:
/// cmark splits `<details>` into **three siblings** — the open tag, the inner
/// Markdown parsed properly as Markdown, the close tag — so this no longer owns
/// a whole section and recurses into it. It reads one raw block at a time and
/// says what happened in it (``Event``); the parser keeps the stack.
enum MarkdownHTMLText {
    // MARK: - Block-level events

    /// A tag that holds *blocks* rather than words. These are the two the
    /// parser has to keep a stack for, because their contents are separate
    /// siblings in the tree.
    enum Container: Equatable {
        case details(isOpen: Bool)
        case blockquote

        /// True when `other` closes the same kind of thing this opened.
        func matches(_ other: Container) -> Bool {
            switch (self, other) {
            case (.details, .details), (.blockquote, .blockquote): true
            default: false
            }
        }
    }

    /// What one `HTMLBlock` turned out to say, in the order it said it.
    enum Event {
        case open(Container)
        case close(Container)
        /// A `<summary>`, already rewritten as Markdown. It belongs to whatever
        /// `<details>` is open around it.
        case summary(String)
        /// A `<table>` read whole. Cells hold Markdown.
        case table(headers: [String], rows: [[String]])
        /// Everything that was not one of the above, rewritten as the Markdown
        /// that says the same thing — for the parser to read as a document of
        /// its own. This is what turns a README's
        /// `<p align="center"><img …></p>` into a picture.
        case markdown(String)
    }

    /// Reads one raw HTML block into the events above.
    ///
    /// A comment goes nowhere: `<!-- … -->` is dropped here rather than cut out
    /// of the source beforehand, which is what keeps every source range in the
    /// document pointing at the line it was written on — and a tickable
    /// checkbox is a source range.
    static func events(in rawHTML: String) -> [Event] {
        var events: [Event] = []
        var loose = ""
        var index = rawHTML.startIndex

        /// Whatever plain HTML has piled up since the last structural tag.
        func flush() {
            defer { loose = "" }
            let text = markdown(from: loose)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            events.append(.markdown(text))
        }

        while index < rawHTML.endIndex {
            // A comment, which the reader was never meant to see.
            if rawHTML[index] == "<", rawHTML[index...].hasPrefix("<!--") {
                let after = rawHTML.index(index, offsetBy: 4)
                guard let end = rawHTML.range(of: "-->", range: after..<rawHTML.endIndex) else {
                    index = rawHTML.endIndex
                    continue
                }
                index = end.upperBound
                continue
            }
            guard rawHTML[index] == "<", let found = tag(at: index, in: rawHTML[...]) else {
                loose.append(rawHTML[index])
                index = rawHTML.index(after: index)
                continue
            }

            switch found.name {
            case "details":
                flush()
                events.append(
                    found.isClosing
                        ? .close(.details(isOpen: false))
                        : .open(.details(isOpen: attributeIsSet("open", in: found.attributes)))
                )
                index = found.range.upperBound
            case "blockquote":
                flush()
                events.append(found.isClosing ? .close(.blockquote) : .open(.blockquote))
                index = found.range.upperBound
            case "summary" where !found.isClosing:
                flush()
                let (text, end) = contents(of: "summary", after: found, in: rawHTML)
                events.append(.summary(markdown(from: text).trimmingCharacters(in: .whitespacesAndNewlines)))
                index = end
            case "table" where !found.isClosing:
                flush()
                let (inner, end) = contents(of: "table", after: found, in: rawHTML)
                if let table = table(in: inner) {
                    events.append(.table(headers: table.headers, rows: table.rows))
                }
                index = end
            default:
                // Not structural: leave it in the buffer for `markdown(from:)`,
                // which knows the inline spelling of the ones worth keeping.
                loose += rawHTML[found.range]
                index = found.range.upperBound
            }
        }

        flush()
        return events
    }

    /// The text between an opening tag and the one that closes it, counting
    /// tags of the same name so a nested one does not end it early, plus the
    /// index just past the close. A tag that is never closed takes the rest,
    /// which is the reading a browser gives it too.
    private static func contents(
        of name: String,
        after opening: HTMLTag,
        in text: String
    ) -> (inner: String, end: String.Index) {
        var index = opening.range.upperBound
        var depth = 1
        while index < text.endIndex {
            guard text[index] == "<", let found = tag(at: index, in: text[...]) else {
                index = text.index(after: index)
                continue
            }
            if found.name == name {
                depth += found.isClosing ? -1 : 1
                if depth == 0 {
                    return (String(text[opening.range.upperBound..<found.range.lowerBound]), found.range.upperBound)
                }
            }
            index = found.range.upperBound
        }
        return (String(text[opening.range.upperBound...]), text.endIndex)
    }

    // MARK: - Tables

    /// A `<table>` read into the same headers and rows a `|…|` table gives.
    ///
    /// The header is whichever row is written with `<th>`; a table with none is
    /// read with its first row as the header, because a table drawn with no
    /// header band at all is not a shape the preview has.
    private static func table(in html: String) -> (headers: [String], rows: [[String]])? {
        var rows: [[String]] = []
        var headerRow: Int?
        var index = html.startIndex

        while index < html.endIndex {
            guard html[index] == "<", let found = tag(at: index, in: html[...]) else {
                index = html.index(after: index)
                continue
            }
            switch found.name {
            case "tr" where !found.isClosing:
                rows.append([])
                index = found.range.upperBound
            case "th", "td":
                guard !found.isClosing else {
                    index = found.range.upperBound
                    continue
                }
                if rows.isEmpty { rows.append([]) }
                if found.name == "th", headerRow == nil { headerRow = rows.count - 1 }
                let (inner, end) = contents(of: found.name, after: found, in: html)
                rows[rows.count - 1].append(
                    markdown(from: inner).trimmingCharacters(in: .whitespacesAndNewlines)
                )
                index = end
            default:
                index = found.range.upperBound
            }
        }

        rows.removeAll { $0.isEmpty }
        guard !rows.isEmpty else { return nil }
        let headers = rows.remove(at: headerRow ?? 0)
        let width = max(headers.count, rows.map(\.count).max() ?? 0)
        return (
            headers: headers + Array(repeating: "", count: width - headers.count),
            rows: rows.map { $0 + Array(repeating: "", count: width - $0.count) }
        )
    }

    // MARK: - Inline

    /// What one `InlineHTML` node — a tag in the middle of a sentence — turns
    /// into.
    enum Inline {
        /// The Markdown that says the same thing, `**` for `<b>` and so on.
        case markdown(String)
        /// An `<img>`, which is a block of its own in the preview rather than
        /// something a line of text can hold.
        case image(source: String, alt: String, width: CGFloat?)
        /// A tag with no meaning here: dropped, its text kept.
        case nothing
    }

    /// One inline tag, read. `links` carries the addresses of the `<a>` tags
    /// still open, so the closing tag writes the address of the one it belongs
    /// to; the caller keeps it across a paragraph's nodes.
    static func inline(_ rawHTML: String, links: inout [String]) -> Inline {
        // Bookkeeping a bot hides mid-sentence.
        if rawHTML.hasPrefix("<!--") { return .nothing }
        guard let found = tag(at: rawHTML.startIndex, in: rawHTML[...]) else { return .nothing }
        if found.name == "img", !found.isClosing {
            guard let address = attribute("src", in: found.attributes) else { return .nothing }
            return .image(
                source: address,
                alt: attribute("alt", in: found.attributes) ?? "",
                width: pixels(attribute("width", in: found.attributes)).map(CGFloat.init)
            )
        }
        let text = markdown(for: found, links: &links)
        return text.isEmpty ? .nothing : .markdown(text)
    }

    /// A run of HTML rewritten as the Markdown that says the same thing, so the
    /// parser downstream needs to know nothing about tags. A tag with no
    /// Markdown spelling — `<div>`, `<span>`, a stray `<p>` — is dropped and its
    /// text kept, though the ones that mean "a new block starts here" leave the
    /// blank line that says so.
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
        case "hr": return "\n\n---\n\n"
        // A block tag's whole meaning here is "the next thing starts on its
        // own", and a blank line is how Markdown says that. This is what makes
        // a README's `<p align="center"><img …></p>` come out as a picture
        // rather than as a word in whatever paragraph ran before it.
        case "p", "div", "ul", "ol", "table", "tr", "section", "blockquote": return "\n\n"
        case "li": return tag.isClosing ? "" : "\n- "
        case "h1", "h2", "h3", "h4", "h5", "h6":
            guard !tag.isClosing, let level = Int(tag.name.dropFirst()) else { return "\n\n" }
            return "\n\n" + String(repeating: "#", count: level) + " "
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

    /// An attribute that is its own value — `<details open>`, which a host also
    /// writes as `open=""` and `open="open"`.
    private static func attributeIsSet(_ name: String, in attributes: String) -> Bool {
        attributes
            .split(whereSeparator: { $0.isWhitespace })
            .contains { $0.lowercased() == name || $0.lowercased().hasPrefix(name + "=") }
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
}
