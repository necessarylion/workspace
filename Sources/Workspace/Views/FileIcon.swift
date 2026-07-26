import SwiftUI

/// Maps a filename to an icon and tint, so the tree reads at a glance.
///
/// A format with a logo of its own — TypeScript, YAML, Docker — is drawn as
/// that logo (see ``BrandMark``) in the language's own colour; everything else
/// falls back to an SF Symbol. Files without an extension (Dockerfile,
/// Makefile) are matched on the whole name, and so are the dotfiles whose name
/// is the whole story.
enum FileIcon {
    /// The logo to draw for this file, if the ecosystem has one.
    static func brand(for url: URL) -> (name: String, color: Color)? {
        // A spec sits next to the thing it tests, so the language's own logo is
        // the one icon it must not borrow — see ``isTest``.
        if isTest(url) { return nil }
        if let named = namedBrand(for: url.lastPathComponent.lowercased()) { return named }

        return switch url.pathExtension.lowercased() {
        case "ts", "mts", "cts": ("typescript", .typescript)
        case "tsx": ("react", .react)
        case "js", "mjs", "cjs": ("javascript", .javascript)
        case "jsx": ("react", .react)
        case "md", "markdown", "mdx": ("markdown", .markdown)
        case "yml", "yaml": ("yaml", .yaml)
        case "toml": ("toml", .brown)
        case "json", "jsonc", "json5": ("json", .json)
        case "xml", "plist": ("xml", .xml)
        case "env": ("dotenv", .env)
        case "py", "pyi": ("python", .python)
        case "rb", "erb", "gemspec": ("ruby", .ruby)
        case "go": ("go", .golang)
        case "rs": ("rust", .rust)
        case "php": ("php", .php)
        case "java": ("openjdk", .java)
        case "kt", "kts": ("kotlin", .kotlin)
        case "cs": ("dotnet", .csharp)
        case "cpp", "cc", "cxx", "hpp": ("cplusplus", .cplusplus)
        case "c", "h": ("c", .cplusplus)
        case "swift": ("swift", .orange)
        case "dart": ("dart", .dart)
        case "lua": ("lua", .lua)
        case "html", "htm": ("html5", .html)
        case "css": ("css3", .css)
        case "scss", "sass", "less": ("sass", .sass)
        case "vue": ("vuedotjs", .vue)
        case "svelte": ("svelte", .svelte)
        case "sql": ("postgresql", .sql)
        case "prisma": ("prisma", .prisma)
        case "tf", "tfvars": ("terraform", .terraform)
        case "graphql", "gql": ("graphql", .graphql)
        case "sh", "bash", "zsh", "fish": ("gnubash", .green)
        case "dockerfile": ("docker", .docker)
        case "pdf": ("acrobat", .pdf)
        default: nil
        }
    }

    /// Whether the file is a test for the file beside it, by the naming each
    /// ecosystem happens to use. Only for languages that write tests as source
    /// files — `notes.test` or `data_spec.json` are not tests of anything.
    static func isTest(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        guard testableExtensions.contains(ext) else { return false }

        let stem = url.deletingPathExtension().lastPathComponent.lowercased()
        // app.spec.ts, api.test.js
        if stem.hasSuffix(".spec") || stem.hasSuffix(".test") { return true }
        // handler_test.go, user_spec.rb
        if stem.hasSuffix("_test") || stem.hasSuffix("_spec") { return true }
        // test_parser.py
        if stem.hasPrefix("test_") { return true }
        // StoreTests.swift — the CamelCase suffix, so only where it is the
        // convention; plain English words end in "tests" too.
        if camelCaseTestExtensions.contains(ext), stem.hasSuffix("tests") { return true }
        return false
    }

    /// Languages whose tests live in source files of the same kind.
    private static let testableExtensions: Set<String> = [
        "ts", "tsx", "mts", "cts", "js", "jsx", "mjs", "cjs",
        "py", "rb", "go", "rs", "php", "java", "kt", "kts", "swift", "dart", "cs",
    ]

    private static let camelCaseTestExtensions: Set<String> = ["swift", "kt", "kts", "java", "cs"]

    /// Files whose whole name carries the meaning — including the dotfiles a
    /// repository is half made of.
    private static func namedBrand(for name: String) -> (name: String, color: Color)? {
        if name == "dockerfile" || name.hasPrefix("dockerfile.") || name == ".dockerignore" {
            return ("docker", .docker)
        }
        if name.hasPrefix("docker-compose.") || name.hasPrefix("compose.") || name == ".docker" {
            return ("docker", .docker)
        }
        if name == "package.json" || name == ".nvmrc" || name == ".node-version" {
            return ("nodedotjs", .node)
        }
        if name == "package-lock.json" || name == ".npmrc" {
            return ("npm", .npm)
        }
        if name.hasPrefix(".env") {
            return ("dotenv", .env)
        }
        if name.hasPrefix(".git") || name == ".mailmap" {
            return ("git", .git)
        }
        if name == "nginx.conf" || name.hasPrefix("nginx.") {
            return ("nginx", .nginx)
        }
        return nil
    }

    static func symbol(for url: URL, isDirectory: Bool = false) -> String {
        if isDirectory { return "folder" }
        if isTest(url) { return "testtube.2" }
        let name = url.lastPathComponent.lowercased()
        if name == "dockerfile" || name.hasPrefix("dockerfile.") || name.hasPrefix("docker-compose.") {
            return "shippingbox"
        }
        if name.hasPrefix(".git") { return "arrow.triangle.branch" }
        if name.hasPrefix("license") || name.hasPrefix("licence") { return "checkmark.seal" }
        if name == "makefile" || name == "gnumakefile" || name == "justfile" { return "hammer" }

        switch url.pathExtension.lowercased() {
        case "csv", "tsv": return "tablecells"
        case "swift": return "swift"
        case "md", "markdown", "mdx", "txt", "rtf": return "doc.text"
        case "json", "jsonc", "json5", "yaml", "yml", "toml", "plist", "xml": return "curlybraces"
        case "png", "jpg", "jpeg", "gif", "heic", "tiff", "webp", "bmp", "icns": return "photo"
        case "svg": return "scribble"
        case "drawio", "dio": return "rectangle.connected.to.line.below"
        case "sh", "bash", "zsh", "fish": return "terminal"
        case "lock": return "lock"
        case "ttf", "otf", "woff", "woff2": return "textformat"
        case "mp4", "mov", "avi", "webm": return "film"
        case "mp3", "wav", "aac", "flac": return "waveform"
        case "js", "jsx", "ts", "tsx", "py", "rb", "rs", "go", "c", "h", "cpp", "m", "mm", "java", "kt":
            return "chevron.left.forwardslash.chevron.right"
        case "pdf": return "doc.richtext"
        case "zip", "gz", "tar", "dmg": return "shippingbox"
        default: return "doc"
        }
    }

    static func tint(for url: URL, isDirectory: Bool = false) -> Color {
        if isDirectory { return .accentColor }
        if isTest(url) { return .test }
        let name = url.lastPathComponent.lowercased()
        if name.hasPrefix(".git") { return .git }

        switch url.pathExtension.lowercased() {
        case "swift": return .orange
        case "md", "markdown", "mdx": return .markdown
        case "json", "jsonc", "json5", "yaml", "yml", "toml", "plist", "xml": return .purple
        case "png", "jpg", "jpeg", "gif", "heic", "tiff", "webp", "bmp", "icns", "svg": return .pink
        case "sh", "bash", "zsh", "fish": return .green
        case "mp4", "mov", "avi", "webm", "mp3", "wav", "aac", "flac": return .indigo
        default: return .secondary
        }
    }
}

/// The mark colours, roughly the ones each ecosystem uses itself, pulled a
/// little towards grey so a long file list does not turn into a paint chart.
private extension Color {
    static let react = Color(red: 0.35, green: 0.76, blue: 0.90)
    static let json = Color(red: 0.55, green: 0.55, blue: 0.58)
    static let xml = Color(red: 0.60, green: 0.45, blue: 0.75)
    static let dart = Color(red: 0.02, green: 0.60, blue: 0.85)
    static let lua = Color(red: 0.25, green: 0.25, blue: 0.72)
    static let prisma = Color(red: 0.27, green: 0.36, blue: 0.44)
    static let terraform = Color(red: 0.48, green: 0.35, blue: 0.87)
    static let node = Color(red: 0.34, green: 0.66, blue: 0.27)
    static let npm = Color(red: 0.80, green: 0.20, blue: 0.20)
    static let nginx = Color(red: 0.00, green: 0.60, blue: 0.35)
    static let typescript = Color(red: 0.19, green: 0.46, blue: 0.75)
    static let javascript = Color(red: 0.78, green: 0.65, blue: 0.05)
    static let markdown = Color(red: 0.36, green: 0.55, blue: 0.85)
    static let yaml = Color(red: 0.80, green: 0.27, blue: 0.27)
    static let docker = Color(red: 0.14, green: 0.59, blue: 0.93)
    static let python = Color(red: 0.22, green: 0.48, blue: 0.72)
    static let ruby = Color(red: 0.80, green: 0.21, blue: 0.18)
    static let golang = Color(red: 0.00, green: 0.66, blue: 0.83)
    static let rust = Color(red: 0.85, green: 0.44, blue: 0.22)
    static let php = Color(red: 0.47, green: 0.44, blue: 0.70)
    static let java = Color(red: 0.79, green: 0.36, blue: 0.16)
    static let kotlin = Color(red: 0.49, green: 0.35, blue: 0.80)
    static let csharp = Color(red: 0.40, green: 0.31, blue: 0.71)
    static let cplusplus = Color(red: 0.26, green: 0.45, blue: 0.71)
    static let html = Color(red: 0.90, green: 0.45, blue: 0.20)
    static let css = Color(red: 0.20, green: 0.47, blue: 0.80)
    static let sass = Color(red: 0.80, green: 0.36, blue: 0.60)
    static let vue = Color(red: 0.25, green: 0.72, blue: 0.51)
    static let svelte = Color(red: 0.90, green: 0.32, blue: 0.12)
    static let sql = Color(red: 0.20, green: 0.62, blue: 0.60)
    static let graphql = Color(red: 0.89, green: 0.20, blue: 0.60)
    static let git = Color(red: 0.94, green: 0.33, blue: 0.20)
    static let env = Color(red: 0.83, green: 0.68, blue: 0.22)
    static let pdf = Color(red: 0.86, green: 0.24, blue: 0.24)
    static let test = Color(red: 0.34, green: 0.70, blue: 0.50)
}
