import AppKit
import CoreText

/// Makes SF Mono nameable, which on a stock Mac it is not.
///
/// SF Mono is the face Xcode and Terminal set code in, and the one
/// ``AppearanceSettings/sfMono(size:)`` resolves to through
/// `monospacedSystemFont`. But Apple never registers it as a family: it is
/// absent from `NSFontManager.availableFontFamilies`, and `NSFont(name:)` and
/// CoreText descriptor matching both fail on "SF Mono". Only
/// `.AppleSystemUIFontMonospaced` reaches it, and that name is Apple's own —
/// asking for it directly gets a console warning and Times New Roman.
///
/// Terminal.app carries the real files and registers them for itself, which is
/// why its font picker offers SF Mono and ours did not. Registering the same
/// files here, `.process`-scoped, buys two things:
///
/// - the Settings picker lists it, so it can be chosen for the editor and the
///   diff like any other installed face;
/// - **the terminal gets it too.** libghostty runs in this process and looks its
///   `font-family` up through CoreText, so a font registered here is a font it
///   can find. Nothing is passed to it beyond the name.
///
/// Nothing is copied and nothing is redistributed — this registers the system's
/// own copy, in this process only, and unregisters itself when the process ends.
/// If the files are not there the app simply carries on: every caller already
/// falls back, and the fallback is the same typeface under Apple's private name.
enum SFMonoFont {
    /// Terminal.app's copy. An implementation detail of another app's bundle,
    /// hence read-only, best-effort, and never assumed to exist.
    private static let directory =
        "/System/Applications/Utilities/Terminal.app/Contents/Resources/Fonts"

    /// True when the family is available under the name "SF Mono".
    ///
    /// A `static let` so the work happens once, on first use, however many
    /// callers there are and whichever gets there first.
    @discardableResult
    static func register() -> Bool { isRegistered }

    private static let isRegistered: Bool = {
        // Already there — a Mac with Apple's developer fonts installed needs
        // nothing from us.
        if NSFont(name: "SF Mono", size: 12) != nil { return true }

        let base = URL(fileURLWithPath: directory)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else {
            return false
        }
        let faces = names
            .filter { $0.hasPrefix("SF-Mono") && $0.hasSuffix(".otf") }
            .sorted()
            .map { base.appendingPathComponent($0) }
        guard !faces.isEmpty else { return false }

        // Deprecated in favour of `CTFontManagerRegisterFontURLs`, and used
        // anyway on purpose: the replacement registers *asynchronously*, and the
        // list of installed faces is built once and cached, so a font that
        // arrives a moment later can miss the picker entirely. This one answers
        // before it returns. Deprecated is not gone.
        //
        // The error out-parameter is an array — one entry per file that failed —
        // and a partial failure still leaves the rest registered, so the answer
        // comes from asking for the font rather than from the return value.
        var errors: Unmanaged<CFArray>?
        CTFontManagerRegisterFontsForURLs(faces as CFArray, .process, &errors)
        return NSFont(name: "SF Mono", size: 12) != nil
    }()
}
