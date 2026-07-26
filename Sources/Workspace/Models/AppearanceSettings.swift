import AppKit
import CoreText
import SwiftUI

/// The fonts the app shows code in — the editor, the diff, and the terminal.
///
/// One face is shared by the editor and the diff, because they show the same
/// thing; only the size differs, since a diff is read at a glance and a file is
/// read line by line. The terminal is left alone unless asked: libghostty
/// already reads the user's own `config`, and overriding it by default would
/// throw away a font they chose there.
@MainActor
@Observable
final class AppearanceSettings {
    static let shared = AppearanceSettings()

    /// The family code is shown in, or nil for the system monospaced face.
    var codeFontName: String? {
        didSet { store(codeFontName, forKey: Keys.codeFont) }
    }

    var editorFontSize: Double {
        didSet { UserDefaults.standard.set(editorFontSize, forKey: Keys.editorSize) }
    }

    var diffFontSize: Double {
        didSet { UserDefaults.standard.set(diffFontSize, forKey: Keys.diffSize) }
    }

    /// Editor line height, as a multiple of the font's own height.
    var editorLineHeight: Double {
        didSet { UserDefaults.standard.set(editorLineHeight, forKey: Keys.lineHeight) }
    }

    /// False leaves the terminal to the user's own Ghostty config.
    var overridesTerminalFont: Bool {
        didSet {
            UserDefaults.standard.set(overridesTerminalFont, forKey: Keys.terminalOverride)
            GhosttyRuntime.applyConfigurationIfRunning()
        }
    }

    var terminalFontName: String? {
        didSet {
            store(terminalFontName, forKey: Keys.terminalFont)
            GhosttyRuntime.applyConfigurationIfRunning()
        }
    }

    var terminalFontSize: Double {
        didSet {
            UserDefaults.standard.set(terminalFontSize, forKey: Keys.terminalSize)
            GhosttyRuntime.applyConfigurationIfRunning()
        }
    }

    /// What the sizes fall back to, and what Restore Defaults puts back.
    enum Default {
        static let editorSize: Double = 12.5
        /// A diff is denser than a file on purpose: two columns have to fit.
        static let diffSize: Double = 10
        static let terminalSize: Double = 13
        static let lineHeight: Double = 1.0
    }

    static let sizeRange: ClosedRange<Double> = 8...28
    static let lineHeightRange: ClosedRange<Double> = 1...2

    private enum Keys {
        static let codeFont = "appearance.codeFont"
        static let editorSize = "appearance.editorFontSize"
        static let diffSize = "appearance.diffFontSize"
        static let lineHeight = "appearance.editorLineHeight"
        static let terminalOverride = "appearance.terminalFontOverride"
        static let terminalFont = "appearance.terminalFont"
        static let terminalSize = "appearance.terminalFontSize"
    }

    private init() {
        let defaults = UserDefaults.standard
        codeFontName = defaults.string(forKey: Keys.codeFont)
        terminalFontName = defaults.string(forKey: Keys.terminalFont)
        overridesTerminalFont = defaults.bool(forKey: Keys.terminalOverride)
        // `double(forKey:)` answers 0 for a key that was never written, which is
        // not a font size — read those as "never set".
        editorFontSize = Self.size(defaults.double(forKey: Keys.editorSize), or: Default.editorSize)
        diffFontSize = Self.size(defaults.double(forKey: Keys.diffSize), or: Default.diffSize)
        terminalFontSize = Self.size(defaults.double(forKey: Keys.terminalSize), or: Default.terminalSize)

        let storedLineHeight = defaults.double(forKey: Keys.lineHeight)
        editorLineHeight = Self.lineHeightRange.contains(storedLineHeight)
            ? storedLineHeight
            : Default.lineHeight
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
        SyntaxTheme(font: editorFont, lineHeightMultiple: editorLineHeight)
    }

    /// The diff's font, as SwiftUI wants it. Fixed size rather than a text
    /// style: a diff column only lines up while every row is the same size.
    var diffFont: Font { Self.swiftUIFont(named: codeFontName, size: diffFontSize) }

    /// For the preview rows in Settings.
    func previewFont(named name: String?, size: Double) -> Font {
        Self.swiftUIFont(named: name, size: size)
    }

    /// The face itself, falling back to the system monospaced one whenever the
    /// name is missing — a font can be uninstalled after it was chosen.
    static func font(named name: String?, size: Double) -> NSFont {
        guard let name, let font = NSFont(name: name, size: size) else {
            return .monospacedSystemFont(ofSize: size, weight: .regular)
        }
        return font
    }

    private static func swiftUIFont(named name: String?, size: Double) -> Font {
        guard let name, NSFont(name: name, size: size) != nil else {
            return .system(size: size, design: .monospaced)
        }
        return .custom(name, fixedSize: size)
    }

    // MARK: - The faces on offer

    /// The name shown for "no face chosen".
    static let systemFaceTitle = "System Monospaced"

    /// Every monospaced family installed on this Mac, sorted by name.
    ///
    /// The `monoSpace` trait alone is not enough: fonts made for code — Fira
    /// Code and the other ligature families among them — often leave it unset,
    /// so a family also counts when a narrow and a wide letter measure the
    /// same. Symbol fonts are dropped, since those measure equal too.
    static let availableFaces: [String] = {
        NSFontManager.shared.availableFontFamilies
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
            || overridesTerminalFont
    }

    func restoreDefaults() {
        codeFontName = nil
        editorFontSize = Default.editorSize
        diffFontSize = Default.diffSize
        editorLineHeight = Default.lineHeight
        terminalFontName = nil
        terminalFontSize = Default.terminalSize
        // Last, so the terminal is rebuilt once, with everything else already back.
        overridesTerminalFont = false
    }
}
