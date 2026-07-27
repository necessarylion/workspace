import Foundation

/// Bitbucket Cloud's mentions, in both directions: names for reading, ids for
/// the host.
///
/// **Coming in**, the Markdown is repaired using the HTML handed back beside
/// it. **Going out**, the name you picked in the composer becomes the id that
/// actually notifies somebody — see ``encodingMentions(in:people:)``.
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

    // MARK: - On the way out

    /// The other direction: `@dale` back to the `@{account_id}` Bitbucket Cloud
    /// needs, for a comment on its way to the host.
    ///
    /// The box you write in keeps the name — see
    /// ``ReviewerCandidate/mentionDisplay`` — so this is where a mention picked
    /// out of the list becomes the thing that actually notifies somebody.
    ///
    /// Only people the host itself offered are translated, so a name that
    /// merely looks like one is left as written. **Longest name first**: with
    /// both `ada` and `adam` on the repository, `@adam` must not be read as
    /// `@ada` with a stray `m` after it. Data Center needs nothing done — there
    /// the name *is* the username, and no candidate carries an id.
    static func encodingMentions(
        in markdown: String,
        people: [ReviewerCandidate]
    ) -> String {
        guard markdown.contains("@") else { return markdown }
        let named = people
            .filter { !($0.accountID ?? "").isEmpty && !$0.name.isEmpty }
            .sorted { $0.name.count > $1.name.count }
        guard !named.isEmpty else { return markdown }

        var result = markdown
        for person in named {
            result = replacingMention(
                person.mentionDisplay,
                with: person.mention(on: .bitbucket),
                in: result
            )
        }
        return result
    }

    /// Replaces `needle` only where it stands as a mention of its own.
    ///
    /// Written out rather than done with a regular expression because the
    /// needle is somebody's name: a `.` or a `+` in it would be pattern syntax,
    /// and escaping a name to search for it literally is more code than this.
    private static func replacingMention(
        _ needle: String,
        with replacement: String,
        in text: String
    ) -> String {
        guard text.contains(needle) else { return text }

        var result = ""
        var index = text.startIndex
        while let found = text.range(of: needle, range: index..<text.endIndex) {
            // The `@` has to start a word — which is what keeps an email
            // address out of it — and the name has to end where it ends,
            // rather than partway through a longer one.
            let opensWord = found.lowerBound == text.startIndex
                || !isNameCharacter(text[text.index(before: found.lowerBound)])
            let endsWord = found.upperBound == text.endIndex
                || !isNameCharacter(text[found.upperBound])

            result += text[index..<found.lowerBound]
            result += opensWord && endsWord ? replacement : needle
            index = found.upperBound
        }
        result += text[index...]
        return result
    }

    private static func isNameCharacter(_ character: Character) -> Bool {
        character.isLetter
            || character.isNumber
            || "-_.@".contains(character)
    }

    // MARK: - On the way in

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
