import AppKit
import SwiftUI

/// A real logo — TypeScript's, Docker's, GitHub's — where SF Symbols has none
/// and a lettered badge only says what you already read in the filename.
///
/// The artwork is inlined as path data rather than shipped as a resource:
/// `Scripts/bundle.sh` wraps a bare executable, so there is no resource bundle
/// to read from. AppKit renders SVG data natively, and a template image takes
/// the foreground colour exactly as a symbol does.
struct BrandMark: View {
    /// A key of ``BrandPath/all``.
    let name: String
    var size: CGFloat = 13
    var color: Color = .primary

    var body: some View {
        if let image = BrandArtwork.image(named: name) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .foregroundStyle(color)
        }
    }
}

enum BrandArtwork {
    /// Decoding an SVG is not free and a file tree asks for the same handful of
    /// marks hundreds of times, so each one is built once and kept.
    /// Main-actor-isolated like its only accessor, which is what makes the
    /// mutable static safe under Swift 6.
    @MainActor private static var cache: [String: NSImage?] = [:]

    /// Nil for a name we have no mark for — the caller falls back to a symbol.
    @MainActor
    static func image(named name: String) -> NSImage? {
        if let cached = cache[name] { return cached }
        let image = render(name)
        cache[name] = image
        return image
    }

    @MainActor
    private static func render(_ name: String) -> NSImage? {
        guard let path = BrandPath.all[name] else { return nil }
        let grid = BrandPath.grid(for: name)
        let svg = """
        <svg viewBox="0 0 \(grid) \(grid)" xmlns="http://www.w3.org/2000/svg"><path d="\(path)"/></svg>
        """
        guard let image = NSImage(data: Data(svg.utf8)) else { return nil }
        image.isTemplate = true
        return image
    }

    /// Whether a mark exists, without building it.
    static func has(_ name: String) -> Bool { BrandPath.all[name] != nil }
}

// MARK: - Claude

/// Claude's own mark, drawn from artwork we ship rather than borrowed from the
/// desktop app's icon — the CLI is what these buttons run, and that does not
/// mean the desktop app is installed. The resource is the whole tile, mark and
/// terracotta together, so nothing about the artwork is reconstructed here.
struct ClaudeMark: View {
    var size: CGFloat = 15

    /// The radius the tile is rounded by, as a fraction of its side — macOS'
    /// own app-icon proportion, because the mark sits beside real app icons.
    private static let cornerFraction: CGFloat = 0.225

    /// Read once, by URL like every other resource here rather than through
    /// `Image(_:bundle:)`: on macOS that initialiser resolves a name against an
    /// asset catalogue, and a file copied in by `.process` is a loose one, so
    /// it comes back empty rather than failing. The artwork stays an SVG —
    /// AppKit keeps it as a vector rep, which is what lets one 2 KB file serve
    /// every size below without a set of bitmaps.
    ///
    /// The corners are rounded into the image rather than clipped in the view:
    /// one of these is a segment of a segmented `Picker`, and that flattens a
    /// segment's label down to a plain image, losing any shape clipped around
    /// it. Drawing through a handler keeps the rounding vector too — it runs
    /// again at whatever resolution the image is asked to rasterise at.
    ///
    /// `isTemplate` is forced off because a template is filled with the accent
    /// colour, and two of these sit inside buttons where that is not the
    /// default one.
    @MainActor private static let artwork: NSImage? = {
        guard let url = Bundle.module.url(forResource: "claude-mark", withExtension: "svg"),
              let source = NSImage(contentsOf: url) else { return nil }
        let rounded = NSImage(size: source.size, flipped: false) { rect in
            NSBezierPath(
                roundedRect: rect,
                xRadius: rect.width * cornerFraction,
                yRadius: rect.height * cornerFraction
            ).addClip()
            source.draw(in: rect)
            return true
        }
        rounded.isTemplate = false
        return rounded
    }()

    var body: some View {
        Group {
            if let artwork = Self.artwork {
                Image(nsImage: artwork)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                // Shipped artwork cannot go missing in a built app, but a mark
                // that silently renders as nothing is not worth the risk. Only
                // this branch is clipped — the artwork carries its own corners.
                Color(red: 0.851, green: 0.467, blue: 0.341)
                    .clipShape(RoundedRectangle(cornerRadius: size * Self.cornerFraction))
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Git hosts

/// The mark of the host a repository lives on, sized like the text beside it.
struct GitHostIcon: View {
    let host: GitHostKind
    var size: CGFloat = 13
    /// Grey the mark out, for a header that should stay quiet.
    var isMuted = false

    var body: some View {
        if let name = host.brand {
            BrandMark(name: name, size: size, color: isMuted ? .secondary : host.tint)
        } else {
            Image(systemName: host.symbol)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Pull requests

extension GitHostKind {
    var brand: String? {
        switch self {
        case .github: "github"
        case .bitbucket: "bitbucket"
        case .unknown: nil
        }
    }

    /// Each mark is one colour, so it is drawn in the brand's own.
    var tint: Color {
        switch self {
        case .github: .primary
        case .bitbucket: Color(red: 0.145, green: 0.518, blue: 1.0)
        case .unknown: .secondary
        }
    }
}
