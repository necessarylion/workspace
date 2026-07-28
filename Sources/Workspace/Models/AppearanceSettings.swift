import AppKit
import CoreText
import SwiftUI

/// How the app draws code — the theme, and the fonts the editor, the diff and
/// the terminal are set in.
///
/// **One face and one theme for all three.** They show the same thing in the
/// same window, and a terminal that kept its own colours and its own font was
/// two apps in one pane. Only the size differs, and only for the diff, which is
/// read at a glance rather than line by line. Nothing here is read from the
/// user's Ghostty config any more; what that file still decides is everything
/// we say nothing about — keybindings, shell integration, the rest.
@MainActor
@Observable
final class AppearanceSettings {
    static let shared = AppearanceSettings()

    /// The family code is shown in, or nil for the system monospaced face.
    /// The terminal is set in it too, so a change has to reach ghostty.
    var codeFontName: String? {
        didSet {
            store(codeFontName, forKey: Keys.codeFont)
            GhosttyRuntime.applyConfigurationIfRunning()
        }
    }

    /// The editor's size, and the terminal's — a shell and a file are read the
    /// same way, so they are read at the same size.
    var editorFontSize: Double {
        didSet {
            UserDefaults.standard.set(editorFontSize, forKey: Keys.editorSize)
            GhosttyRuntime.applyConfigurationIfRunning()
        }
    }

    var diffFontSize: Double {
        didSet { UserDefaults.standard.set(diffFontSize, forKey: Keys.diffSize) }
    }

    /// Editor line height, as a multiple of the font's own height.
    var editorLineHeight: Double {
        didSet { UserDefaults.standard.set(editorLineHeight, forKey: Keys.lineHeight) }
    }

    /// The theme the editor, the diff **and the terminal** are drawn with. A
    /// shell takes its background, its text colour and its sixteen ANSI slots
    /// from here too — see ``TerminalPalette`` — so picking a theme in Settings
    /// repaints the shells already running along with everything else.
    var palette: SyntaxPalette {
        didSet {
            UserDefaults.standard.set(palette.name, forKey: Keys.theme)
            GhosttyRuntime.applyConfigurationIfRunning()
        }
    }

    /// What the sizes fall back to, and what Restore Defaults puts back.
    enum Default {
        static let editorSize: Double = 12.5
        /// Still a shade denser than a file — two columns have to fit — but not
        /// so small that a diff is harder to read than the file it came from.
        static let diffSize: Double = 12
        /// The terminal is set in SF Mono too, so a shell and a file read as the
        /// same app rather than as two.
        static let faceName = "SF Mono"
        /// A little air, now the editor is CodeEditSourceEditor. The old 1.0 was
        /// the font's own leading and nothing added, chosen when the pane was
        /// shared three ways and every point went to code. The package's own
        /// default is 1.2 and CodeEdit ships that; this sits between the two —
        /// enough to stop lines running together, not enough to cost a line of
        /// what fits on screen.
        static let lineHeight: Double = 1.1
    }

    static let sizeRange: ClosedRange<Double> = 8...28
    static let lineHeightRange: ClosedRange<Double> = 1...2

    private enum Keys {
        static let codeFont = "appearance.codeFont"
        static let editorSize = "appearance.editorFontSize"
        static let diffSize = "appearance.diffFontSize"
        static let lineHeight = "appearance.editorLineHeight"
        static let theme = "appearance.theme"
        /// The terminal's own face, size and "leave it to Ghostty" switch, which
        /// Settings no longer offers. Cleared once so a Mac that used them is
        /// not carrying three dead keys about.
        static let retiredTerminal = [
            "appearance.terminalFontOverride",
            "appearance.terminalFont",
            "appearance.terminalFontSize"
        ]
    }

    private init() {
        let defaults = UserDefaults.standard
        for key in Keys.retiredTerminal { defaults.removeObject(forKey: key) }
        codeFontName = defaults.string(forKey: Keys.codeFont)
        // `double(forKey:)` answers 0 for a key that was never written, which is
        // not a font size — read those as "never set".
        editorFontSize = Self.size(defaults.double(forKey: Keys.editorSize), or: Default.editorSize)
        diffFontSize = Self.size(defaults.double(forKey: Keys.diffSize), or: Default.diffSize)

        let storedLineHeight = defaults.double(forKey: Keys.lineHeight)
        editorLineHeight = Self.lineHeightRange.contains(storedLineHeight)
            ? storedLineHeight
            : Default.lineHeight

        palette = SyntaxPalette.named(defaults.string(forKey: Keys.theme))
    }

    private static func size(_ stored: Double, or fallback: Double) -> Double {
        sizeRange.contains(stored) ? stored : fallback
    }

    private func store(_ name: String?, forKey key: String) {
        if let name {
            UserDefaults.standard.set(name, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    // MARK: - Fonts

    /// The editor's font — the face the user picked, at the editor's size.
    var editorFont: NSFont { Self.font(named: codeFontName, size: editorFontSize) }

    var editorTheme: SyntaxTheme {
        SyntaxTheme(font: editorFont, lineHeightMultiple: editorLineHeight, palette: palette)
    }

    /// The diff's font, as SwiftUI wants it. Fixed size rather than a text
    /// style: a diff column only lines up while every row is the same size.
    var diffFont: Font { Self.swiftUIFont(named: codeFontName, size: diffFontSize) }

    /// For the preview rows in Settings.
    func previewFont(named name: String?, size: Double) -> Font {
        Self.swiftUIFont(named: name, size: size)
    }

    /// The face itself, falling back to SF Mono whenever the name is missing —
    /// a font can be uninstalled after it was chosen.
    static func font(named name: String?, size: Double) -> NSFont {
        guard let name, let font = NSFont(name: name, size: size) else {
            return sfMono(size: size)
        }
        return font
    }

    /// SF Mono, which is what Xcode sets code in.
    ///
    /// Asked for by name first, because a Mac that has it registered — Apple
    /// gives it away with the developer fonts, and some people install it — then
    /// uses the real thing. Most Macs do not: Apple ships SF Mono privately
    /// inside Terminal and Xcode, so it is absent from `availableFontFamilies`
    /// and `NSFont(name:)` cannot see it.
    ///
    /// `monospacedSystemFont` is the way in either way. It answers
    /// `.AppleSystemUIFontMonospaced`, whose display name is `.SF NS Mono` — the
    /// same face under the name Apple keeps for itself. So the fallback is not a
    /// substitute for SF Mono; it *is* SF Mono.
    static func sfMono(size: Double) -> NSFont {
        NSFont(name: "SF Mono", size: size)
            ?? .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// The family name to hand the terminal: the face code is shown in, so a
    /// shell and a file are set in one face. Falls back to SF Mono, which is
    /// what the editor uses when no face has been chosen — and to nil if even
    /// that is not installed, since libghostty takes a *name* and has no
    /// fallback of ours to reach for.
    var terminalFace: String? {
        if let codeFontName, Self.isInstalled(codeFontName) { return codeFontName }
        return Self.isInstalled(Default.faceName) ? Default.faceName : nil
    }

    /// The size a shell is drawn at — the editor's, for the same reason.
    var terminalFontSize: Double { editorFontSize }

    private static func swiftUIFont(named name: String?, size: Double) -> Font {
        guard let name, NSFont(name: name, size: size) != nil else {
            // Matches `sfMono(size:)`: the named face when this Mac has it,
            // otherwise the system monospaced design, which is the same face.
            if NSFont(name: "SF Mono", size: size) != nil {
                return .custom("SF Mono", fixedSize: size)
            }
            return .system(size: size, design: .monospaced)
        }
        return .custom(name, fixedSize: size)
    }

    // MARK: - The faces on offer

    /// The name shown for "no face chosen" — which resolves to SF Mono, the face
    /// Xcode uses. Named rather than called "System Monospaced", which made the
    /// default read as a nondescript fallback when it is the intended choice.
    static let systemFaceTitle = Default.faceName

    /// Every monospaced family installed on this Mac, sorted by name.
    ///
    /// The `monoSpace` trait alone is not enough: fonts made for code — Fira
    /// Code and the other ligature families among them — often leave it unset,
    /// so a family also counts when a narrow and a wide letter measure the
    /// same. Symbol fonts are dropped, since those measure equal too.
    static let availableFaces: [String] = {
        // Belt and braces — the app registers this at launch, but this list is
        // built on first use and that could come first.
        SFMonoFont.register()
        return NSFontManager.shared.availableFontFamilies
            .filter { !$0.hasPrefix(".") && isMonospaced($0) }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }()

    /// The list a picker should show: the installed faces, plus the chosen one
    /// when it is no longer installed, so a missing font is visible rather than
    /// silently swapped for the system one.
    static func faces(including chosen: String?) -> [String] {
        guard let chosen, !availableFaces.contains(chosen) else { return availableFaces }
        return ([chosen] + availableFaces)
    }

    static func isInstalled(_ name: String?) -> Bool {
        guard let name else { return true }
        return NSFont(name: name, size: 12) != nil
    }

    private static func isMonospaced(_ family: String) -> Bool {
        guard let font = NSFont(name: family, size: 12) else { return false }
        // Wingdings and friends: every glyph is the same width, and none of
        // them is a letter.
        let stylisticClass = CTFontGetSymbolicTraits(font as CTFont).rawValue & 0xF000_0000
        guard stylisticClass != CTFontStylisticClass.symbolicClass.rawValue else { return false }

        if font.fontDescriptor.symbolicTraits.contains(.monoSpace) { return true }
        let narrow = ("i" as NSString).size(withAttributes: [.font: font]).width
        let wide = ("W" as NSString).size(withAttributes: [.font: font]).width
        return narrow > 0 && abs(narrow - wide) < 0.01
    }

    // MARK: - Restoring

    var isCustomised: Bool {
        codeFontName != nil
            || editorFontSize != Default.editorSize
            || diffFontSize != Default.diffSize
            || editorLineHeight != Default.lineHeight
            || palette.name != SyntaxPalette.all[0].name
    }

    func restoreDefaults() {
        diffFontSize = Default.diffSize
        editorLineHeight = Default.lineHeight
        // These three reach the terminal, so they go last — each one rebuilds
        // ghostty's configuration, and the last rebuild should be the one with
        // everything already back.
        codeFontName = nil
        editorFontSize = Default.editorSize
        palette = SyntaxPalette.all[0]
    }
}
