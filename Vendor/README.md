# Vendor

Third-party source checked in verbatim, referenced from `Package.swift` with
`.package(path:)`.

## CodeEditLanguages 0.1.20

Tree-sitter grammars and highlight queries.

Vendored because fetching it is disproportionately expensive: the upstream
repository carries every historical revision of every vendored grammar, so
SwiftPM's `--mirror` clone pulls **~600 MB**. The release source archive for
the same tag is **34 MB** — and 33 MB of that is a single prebuilt
`CodeLanguagesContainer.xcframework.zip`, which the package links as a local
binary target. The Swift source itself is under 1 MB.

The tree is an unmodified extraction of:

```
https://github.com/CodeEditApp/CodeEditLanguages/archive/refs/tags/0.1.20.tar.gz
```

To move to a new version, replace the directory with a fresh extraction of that
URL at the new tag. Its own dependency (`SwiftTreeSitter`, and `tree-sitter`
under it) still resolves from GitHub — those repositories are small.
