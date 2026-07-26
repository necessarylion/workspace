import CodeEditLanguages
import Foundation

extension CodeLanguage {
    /// The language for a file, with the app's own answers for the names the
    /// library's table misses.
    ///
    /// `detectLanguageFrom(url:)` matches on the path extension, falling back
    /// to the whole file name when there is none (`Dockerfile`, `Makefile`).
    /// Neither reaches a dotfile that also carries a suffix: Foundation reads
    /// `.env` as a name with no extension at all, and `.env.example` as one
    /// whose extension is `example`. Every variant holds the same shell-style
    /// `KEY=value` list, so they all get the bash grammar — it colours the
    /// keys, the comments and the quoted values.
    static func forFile(url: URL) -> CodeLanguage {
        if isEnvironmentFile(named: url.lastPathComponent) { return .bash }
        return detectLanguageFrom(url: url)
    }

    /// `.env`, `.env.local`, `.env.example`, `.envrc` — and `staging.env`,
    /// which some projects write the other way round.
    private static func isEnvironmentFile(named name: String) -> Bool {
        let name = name.lowercased()
        return name == ".env"
            || name == ".envrc"
            || name.hasPrefix(".env.")
            || name.hasSuffix(".env")
    }
}
