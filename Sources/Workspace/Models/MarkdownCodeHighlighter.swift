import AppKit
import CodeEditLanguages
import Foundation

/// Syntax colours for a fenced code block in the Markdown preview.
///
/// The same tree-sitter grammars, queries and palette the editor and the diff
/// use — a fence saying `swift` should look like the file it was copied out of.
/// The word after the fence stands in for the file name the editor would have
/// detected the language from.
@MainActor
enum MarkdownCodeHighlighter {
    /// The block's text with a colour on every capture, or nil when the fence
    /// names no language we have a grammar for — then the block stays plain.
    static func highlight(_ code: String, language fence: String) -> AttributedString? {
        guard let language = language(for: fence) else { return nil }

        let key = Key(
            language: language.id.rawValue,
            palette: AppearanceSettings.shared.palette.name,
            code: code
        )
        if let cached = cache[key] { return cached }

        // One parser per language, kept across blocks and across previews:
        // loading a grammar and its query file is the expensive part.
        let highlighter = highlighters[language.id.rawValue] ?? TreeSitterHighlighter(language: language)
        highlighters[language.id.rawValue] = highlighter
        highlighter.setText(code)
        guard highlighter.isReady else { return nil }

        let attributed = NSMutableAttributedString(string: code)
        let fullRange = NSRange(location: 0, length: (code as NSString).length)
        for capture in highlighter.highlights(in: fullRange) {
            // Colours only, no fonts: the block is set in the Markdown view's
            // own monospaced font, the way the diff keeps its denser one.
            guard let color = SyntaxTheme.captureColor(for: capture.capture) else { continue }
            attributed.addAttribute(.foregroundColor, value: color, range: capture.range)
        }

        let result = AttributedString(attributed)
        // A view body can run many times over for the same text, and parsing
        // again each time would be wasted work. The cap is only here so that a
        // long session of opening files cannot grow this without end.
        if cache.count > 200 { cache.removeAll() }
        cache[key] = result
        return result
    }

    /// "swift", "ts", "objective-c", "```js title=x" → a language, if we have
    /// its grammar. Matched against the language's own name first and its file
    /// extensions second, so most fences need no alias at all.
    static func language(for fence: String) -> CodeLanguage? {
        // Fences carry more than a language: ```js {1,3} or ```sh title="run".
        let name = fence
            .lowercased()
            .split(whereSeparator: { $0 == " " || $0 == "{" || $0 == "," })
            .first
            .map(String.init) ?? ""
        guard !name.isEmpty else { return nil }

        if let id = aliases[name] {
            return CodeLanguage.allLanguages.first { $0.id == id }
        }
        if let byName = CodeLanguage.allLanguages.first(where: { $0.id.rawValue.lowercased() == name }) {
            return byName
        }
        return CodeLanguage.allLanguages.first { language in
            language.extensions.contains { $0.lowercased() == name }
        }
    }

    /// Only the fence words the two passes above miss.
    private static let aliases: [String: TreeSitterLanguage] = [
        "c#": .cSharp,
        "console": .bash,
        "dotenv": .bash,
        "env": .bash,
        "golang": .go,
        "jsonc": .json,
        "json5": .json,
        "objective-c": .objc,
        "python3": .python,
        "shell": .bash,
        "xml": .html,
        "zsh": .bash
    ]

    private struct Key: Hashable {
        let language: String
        let palette: String
        let code: String
    }

    private static var highlighters: [String: TreeSitterHighlighter] = [:]
    private static var cache: [Key: AttributedString] = [:]
}
