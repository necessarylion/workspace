import AppKit

/// The theme the editor is drawn with, turned into the colours a terminal
/// needs — the settings ``GhosttyRuntime`` writes on top of the user's own
/// Ghostty config.
///
/// A terminal wants sixteen ANSI slots and a syntax theme names none of them,
/// so they are **taken from the colours the theme already uses**: every capture
/// colour in the palette is a candidate, and each ANSI slot takes the candidate
/// whose hue is nearest to it. Red comes out as whatever red that theme writes
/// keywords or errors in, green as its strings, and so on — without this file
/// having to know which capture a given theme decided to make green. A theme
/// that names nothing near a hue keeps a plain default for that slot, so the
/// sixteen are always complete.
///
/// The alternative — mapping fixed captures onto fixed slots — reads well until
/// a theme colours functions green and strings yellow (which the ones here do),
/// and then `ls` comes out in the wrong colour for that theme alone.
enum TerminalPalette {
    /// The background a shell is drawn on: the editor's, so opening a terminal
    /// where a file was does not change the colour of the pane.
    static func background(for palette: SyntaxPalette) -> NSColor {
        palette.background ?? AppColors.viewerBackground
    }

    /// Every line ghostty needs to draw this theme, in the form its config file
    /// takes. Handed to `ghostty_config_load_file` after the user's own config,
    /// so these win.
    static func configLines(for palette: SyntaxPalette) -> [String] {
        var lines = [
            "background = \(hex(background(for: palette)))",
            "foreground = \(hex(palette.foreground))",
            "cursor-color = \(hex(palette.insertionPoint ?? palette.foreground))"
        ]
        if let selection = palette.selection {
            lines.append("selection-background = \(hex(selection))")
            // Left to the theme's own text colour, the way the editor's
            // selection band works: a selection marks a range, it does not
            // repaint what is in it.
            lines.append("selection-foreground = \(hex(palette.foreground))")
        }
        for (slot, colour) in ansi(for: palette).enumerated() {
            lines.append("palette = \(slot)=#\(hex(colour))")
        }
        return lines
    }

    // MARK: - The sixteen

    /// ANSI 0–15, in the order a terminal numbers them: black, red, green,
    /// yellow, blue, magenta, cyan, white, then the bright half.
    static func ansi(for palette: SyntaxPalette) -> [NSColor] {
        let candidates = ([palette.foreground] + palette.styles.values.map(\.color))
            .compactMap { $0.usingColorSpace(.sRGB) }
        let background = background(for: palette).usingColorSpace(.sRGB)
            ?? AppColors.viewerBackground
        let foreground = palette.foreground.usingColorSpace(.sRGB) ?? palette.foreground

        // Black is not a colour the theme names, and it must not be the
        // background itself — text written in it would be invisible. A step
        // from the background towards the text is what every terminal theme
        // does here.
        let black = blend(background, into: foreground, by: 0.22)
        let normal = Hue.allCases.map { hue in
            nearest(to: hue, among: candidates) ?? hue.fallback
        }
        // The bright half is the same hue with the lamp turned up, rather than
        // eight more colours pulled out of a theme that has not got them.
        let white = palette.lineNumber.usingColorSpace(.sRGB) ?? palette.lineNumber

        return [black] + normal + [foreground]
            + [brighter(white)] + normal.map(brighter) + [brighter(foreground)]
    }

    /// The six hues a terminal has a name for, **declared in the order it
    /// numbers them** — slots 1 to 6, between black and white. `black` and
    /// `white` are not among them: neither is a hue, and both are taken from
    /// the theme's own background, text and gutter colours instead.
    private enum Hue: Double, CaseIterable {
        case red = 0
        case green = 0.333
        case yellow = 0.139
        case blue = 0.611
        case magenta = 0.833
        case cyan = 0.5

        /// What the slot gets when the theme has nothing of that hue in it —
        /// the colours a bare terminal would have used anyway.
        var fallback: NSColor {
            switch self {
            case .red: NSColor(rgb: 0xCC_66_66)
            case .green: NSColor(rgb: 0xB5_BD_68)
            case .yellow: NSColor(rgb: 0xF0_C6_74)
            case .blue: NSColor(rgb: 0x81_A2_BE)
            case .magenta: NSColor(rgb: 0xB2_94_BB)
            case .cyan: NSColor(rgb: 0x8A_BE_B7)
            }
        }
    }

    /// The theme colour closest to this hue, or nil when the theme has nothing
    /// worth calling that colour.
    ///
    /// Grey and near-black are dropped before the comparison: a hue is
    /// meaningless once there is no saturation to carry it, and punctuation
    /// drawn in a flat grey would otherwise win every slot it happened to sit
    /// nearest to.
    private static func nearest(to hue: Hue, among candidates: [NSColor]) -> NSColor? {
        var best: (colour: NSColor, distance: Double)?
        for colour in candidates {
            let saturation = Double(colour.saturationComponent)
            let brightness = Double(colour.brightnessComponent)
            guard saturation >= 0.15, brightness >= 0.25 else { continue }

            let distance = hueDistance(Double(colour.hueComponent), hue.rawValue)
            // A colour more than a sixth of the wheel away is not that colour:
            // taking it would make a theme with three hues in it fill all six
            // slots with them.
            guard distance <= 0.17 else { continue }
            if best == nil || distance < best!.distance {
                best = (colour, distance)
            }
        }
        return best?.colour
    }

    /// How far apart two hues are on a wheel that wraps at 1.
    private static func hueDistance(_ one: Double, _ other: Double) -> Double {
        let raw = abs(one - other)
        return min(raw, 1 - raw)
    }

    /// The bright half of the ANSI palette: the same colour with more light in
    /// it and a little less saturation, which is what a terminal's bright
    /// colours are.
    private static func brighter(_ colour: NSColor) -> NSColor {
        guard let colour = colour.usingColorSpace(.sRGB) else { return colour }
        return NSColor(
            hue: colour.hueComponent,
            saturation: max(colour.saturationComponent - 0.08, 0),
            brightness: min(colour.brightnessComponent + 0.18, 1),
            alpha: 1
        )
    }

    /// `amount` of the way from one colour to another.
    private static func blend(_ from: NSColor, into to: NSColor, by amount: Double) -> NSColor {
        guard let from = from.usingColorSpace(.sRGB), let to = to.usingColorSpace(.sRGB) else {
            return from
        }
        func mix(_ one: CGFloat, _ other: CGFloat) -> CGFloat {
            one + (other - one) * CGFloat(amount)
        }
        return NSColor(
            srgbRed: mix(from.redComponent, to.redComponent),
            green: mix(from.greenComponent, to.greenComponent),
            blue: mix(from.blueComponent, to.blueComponent),
            alpha: 1
        )
    }

    /// `RRGGBB`, which is the only colour form ghostty's config parser takes.
    static func hex(_ colour: NSColor) -> String {
        guard let colour = colour.usingColorSpace(.sRGB) else { return "000000" }
        let red = Int((colour.redComponent * 255).rounded())
        let green = Int((colour.greenComponent * 255).rounded())
        let blue = Int((colour.blueComponent * 255).rounded())
        return String(format: "%02X%02X%02X", red, green, blue)
    }
}
