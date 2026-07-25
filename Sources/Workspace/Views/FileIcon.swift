import SwiftUI

/// Maps a filename to an SF Symbol and tint, so the tree reads at a glance.
enum FileIcon {
    /// Languages that read better as a lettered badge than any SF Symbol.
    static func badge(for url: URL) -> (text: String, color: Color)? {
        switch url.pathExtension.lowercased() {
        case "ts", "mts", "cts", "tsx": ("TS", Color(red: 0.19, green: 0.46, blue: 0.75))
        case "js", "mjs", "cjs", "jsx": ("JS", Color(red: 0.78, green: 0.65, blue: 0.05))
        default: nil
        }
    }

    static func symbol(for url: URL, isDirectory: Bool = false) -> String {
        if isDirectory { return "folder" }
        switch url.pathExtension.lowercased() {
        case "swift": return "swift"
        case "md", "markdown", "mdx", "txt", "rtf": return "doc.text"
        case "json", "yaml", "yml", "toml", "plist", "xml": return "curlybraces"
        case "png", "jpg", "jpeg", "gif", "heic", "tiff", "webp", "bmp", "icns": return "photo"
        case "sh", "bash", "zsh", "fish": return "terminal"
        case "js", "jsx", "ts", "tsx", "py", "rb", "rs", "go", "c", "h", "cpp", "m", "mm", "java", "kt":
            return "chevron.left.forwardslash.chevron.right"
        case "pdf": return "doc.richtext"
        case "zip", "gz", "tar", "dmg": return "shippingbox"
        default: return "doc"
        }
    }

    static func tint(for url: URL, isDirectory: Bool = false) -> Color {
        if isDirectory { return .accentColor }
        switch url.pathExtension.lowercased() {
        case "swift": return .orange
        case "md", "markdown", "mdx": return .blue
        case "json", "yaml", "yml", "toml", "plist", "xml": return .purple
        case "png", "jpg", "jpeg", "gif", "heic", "tiff", "webp", "bmp", "icns": return .pink
        case "sh", "bash", "zsh", "fish": return .green
        default: return .secondary
        }
    }
}
