import Foundation

/// A `#123` written in a commit message — the way both hosts spell "this is the
/// pull request I belong to".
enum PullRequestReference {
    struct Match: Sendable, Hashable {
        /// Where it sits in the message, as UTF-16 offsets — what AppKit's text
        /// drawing wants, since that is what turns them into links.
        var range: NSRange
        var number: Int
    }

    /// A hash followed by digits, with a word character on neither side: that
    /// keeps `#12` out of `abc#12` and `#12ab`, and the digit cap keeps a hex
    /// colour like `#123456` from reading as a pull request.
    private static let pattern = try? NSRegularExpression(
        pattern: "(?<![A-Za-z0-9_#])#([0-9]{1,6})(?![A-Za-z0-9_])"
    )

    static func matches(in text: String) -> [Match] {
        guard let pattern, text.contains("#") else { return [] }
        let whole = NSRange(text.startIndex..<text.endIndex, in: text)
        return pattern.matches(in: text, range: whole).compactMap { match in
            guard let digits = Range(match.range(at: 1), in: text),
                  let number = Int(text[digits]), number > 0
            else { return nil }
            return Match(range: match.range, number: number)
        }
    }
}
