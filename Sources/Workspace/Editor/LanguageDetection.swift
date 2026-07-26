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
    ///
    /// A Vue single-file component has no grammar of its own — the grammars
    /// arrive as a prebuilt binary we cannot add to — so it is coloured as
    /// HTML, which is what its `<template>`, `<script>` and `<style>` blocks
    /// read as. Its *language server* is still the Vue one; that is found by
    /// file name, not by this, in ``LanguageServerCatalog``.
    static func forFile(url: URL) -> CodeLanguage {
        if isEnvironmentFile(named: url.lastPathComponent) { return .bash }
        if url.pathExtension.lowercased() == "vue" { return .html }
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
