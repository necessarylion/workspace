import AppKit
import SwiftUI

/// Every key the app itself binds, and what the user has rebound it to.
///
/// The app's shortcuts live in exactly two places: a menu item in
/// ``WorkspaceApp``, and — for the two the menu bar cannot express — a window
/// key monitor. Both ask this store rather than naming a key, so one setting
/// changes both. Anything the *editor* or the system owns (⌘F, ⌃Space, ⌘Q, a
/// sheet's Cancel and Default buttons) is not here: those are not the app's to
/// give away.
@MainActor
@Observable
final class KeyboardShortcuts {
    static let shared = KeyboardShortcuts()

    /// Only what differs from the default is kept, so an action whose default
    /// changes in a later release follows it. A present-but-nil value is an
    /// action the user deliberately left unbound.
    private var overrides: [ShortcutAction: KeyChord?] = [:]

    private static let storageKey = "shortcuts.overrides"

    private init() {
        overrides = Self.load()
    }

    /// What this action is bound to now, or nil when it has no key.
    func chord(for action: ShortcutAction) -> KeyChord? {
        if let override = overrides[action] { return override }
        return action.defaultChord
    }

    func set(_ chord: KeyChord?, for action: ShortcutAction) {
        if chord == action.defaultChord {
            overrides.removeValue(forKey: action)
        } else {
            overrides[action] = .some(chord)
        }
        save()
    }

    /// Puts one action back to the key the app ships with.
    func reset(_ action: ShortcutAction) {
        overrides.removeValue(forKey: action)
        save()
    }

    func restoreDefaults() {
        overrides.removeAll()
        save()
    }

    var isCustomised: Bool { !overrides.isEmpty }

    func isCustomised(_ action: ShortcutAction) -> Bool { overrides[action] != nil }

    /// The other actions bound to the same key. Two menu items sharing one key
    /// equivalent means only one of them ever fires, so this is worth saying
    /// out loud rather than refusing the second binding — which of the two the
    /// user meant to move is their business, not ours.
    func conflicts(with action: ShortcutAction) -> [ShortcutAction] {
        guard let bound = chord(for: action) else { return [] }
        return ShortcutAction.allCases.filter { $0 != action && chord(for: $0) == bound }
    }

    // MARK: - Storage

    /// Written as a plain `[name: chord]` dictionary, with an empty key
    /// standing for "bound to nothing" — `[String: KeyChord?]` is not something
    /// `JSONEncoder` will take.
    private func save() {
        var stored: [String: KeyChord] = [:]
        for (action, chord) in overrides {
            stored[action.rawValue] = chord ?? KeyChord.unbound
        }
        guard let data = try? JSONEncoder().encode(stored) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }

    private static func load() -> [ShortcutAction: KeyChord?] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let stored = try? JSONDecoder().decode([String: KeyChord].self, from: data)
        else { return [:] }

        var result: [ShortcutAction: KeyChord?] = [:]
        for (name, chord) in stored {
            // An action that no longer exists is dropped rather than kept
            // around — the release that removed it is not coming back.
            guard let action = ShortcutAction(rawValue: name) else { continue }
            result[action] = chord.key.isEmpty ? .some(nil) : .some(chord)
        }
        return result
    }
}

// MARK: - The actions

/// One rebindable command. The raw value is what is written to disk, so it
/// outlives any renaming of the case.
enum ShortcutAction: String, CaseIterable, Identifiable, Sendable {
    case addRepository
    case switchRepository
    case toggleRepositories
    case toggleNavigator

    case save
    case close
    case savePDF

    case goToFile
    case goBack
    case goForward

    case refreshAll
    case askClaude

    case toggleTerminal
    case openTerminal
    case newTerminalTab
    case newHomeTerminal

    case submit

    var id: String { rawValue }

    var title: String {
        switch self {
        case .addRepository: "Add Repository"
        case .switchRepository: "Switch Repository"
        case .toggleRepositories: "Show / Hide Repositories"
        case .toggleNavigator: "Show / Hide Navigator"
        case .save: "Save"
        case .close: "Close"
        case .savePDF: "Save as PDF"
        case .goToFile: "Go to File"
        case .goBack: "Back"
        case .goForward: "Forward"
        case .refreshAll: "Refresh All"
        case .askClaude: "Ask Claude"
        case .toggleTerminal: "Show / Hide Terminal"
        case .openTerminal: "Open Terminal"
        case .newTerminalTab: "New Terminal Tab"
        case .newHomeTerminal: "New Terminal in Home"
        case .submit: "Post / Commit"
        }
    }

    /// What the key does, in the words the user would use for it.
    var detail: String {
        switch self {
        case .addRepository: "Pick a folder to add to the sidebar"
        case .switchRepository: "Hold the modifier and press again to walk the list"
        case .toggleRepositories: "Fold the repository sidebar away"
        case .toggleNavigator: "Fold the navigator away"
        case .save: "Write the open file — or the pull request description — back"
        case .close: "Close whatever the viewer is showing"
        case .savePDF: "Save the Markdown preview as a PDF"
        case .goToFile: "Find a file in the selected repository by name"
        case .goBack: "The item you were looking at before"
        case .goForward: "The item you came back from"
        case .refreshAll: "Re-read every repository's branch, changes and pull requests"
        case .askClaude: "A conversation in a panel over the window, next to the code"
        case .toggleTerminal: "The same key in and back out of the repository's shell"
        case .openTerminal: "Show the selected repository's terminal"
        case .newTerminalTab: "Another shell beside the current one"
        case .newHomeTerminal: "A shell that belongs to no repository"
        case .submit: "Post the comment you typed, or commit the staged files"
        }
    }

    var group: ShortcutGroup {
        switch self {
        case .addRepository, .switchRepository, .toggleRepositories, .toggleNavigator, .refreshAll:
            .repositories
        case .save, .close, .savePDF:
            .file
        case .goToFile, .goBack, .goForward:
            .go
        case .askClaude, .toggleTerminal, .openTerminal, .newTerminalTab, .newHomeTerminal:
            .terminal
        case .submit:
            .writing
        }
    }

    /// The key the app ships with, and what Restore Defaults puts back.
    var defaultChord: KeyChord? {
        switch self {
        case .addRepository: KeyChord("o", [.command, .shift])
        case .switchRepository: KeyChord.tab([.control])
        case .toggleRepositories: KeyChord("0", [.command])
        case .toggleNavigator: KeyChord("0", [.command, .option])
        case .save: KeyChord("s", [.command])
        case .close: KeyChord("w", [.command, .shift])
        case .savePDF: KeyChord("e", [.command, .shift])
        case .goToFile: KeyChord("p", [.command])
        case .goBack: KeyChord("[", [.command])
        case .goForward: KeyChord("]", [.command])
        case .refreshAll: KeyChord("r", [.command])
        case .askClaude: KeyChord("l", [.command, .shift])
        case .toggleTerminal: KeyChord("`", [.control])
        case .openTerminal: KeyChord("t", [.control, .command])
        case .newTerminalTab: KeyChord("t", [.command])
        case .newHomeTerminal: KeyChord("t", [.command, .shift])
        case .submit: KeyChord.return([.command])
        }
    }
}

/// How the list in Settings is broken up — the menus the keys mostly live in.
enum ShortcutGroup: String, CaseIterable, Identifiable {
    case repositories, file, go, terminal, writing

    var id: String { rawValue }

    var title: String {
        switch self {
        case .repositories: "Repositories"
        case .file: "File"
        case .go: "Go"
        case .terminal: "Terminal and Claude"
        case .writing: "Writing"
        }
    }

    var actions: [ShortcutAction] { ShortcutAction.allCases.filter { $0.group == self } }
}

// MARK: - A key and its modifiers

/// One keystroke: the key, plus whatever was held with it.
struct KeyChord: Hashable, Codable, Sendable {
    /// The character the key produces, lowercased — "o", "0", "`" — or the
    /// private-use character SwiftUI gives a key that types nothing, such as ⇥
    /// or ↑. It is what `charactersIgnoringModifiers` reports, which is what
    /// both the menu bar and the key monitor compare against.
    var key: String
    var modifiers: KeyModifiers

    init(_ key: String, _ modifiers: KeyModifiers) {
        self.key = key.lowercased()
        self.modifiers = modifiers
    }

    init(_ key: Character, _ modifiers: KeyModifiers) {
        self.init(String(key), modifiers)
    }

    /// The placeholder written to disk for an action bound to nothing.
    static let unbound = KeyChord("", [])

    /// The two keys the defaults use that type no character of their own.
    static func tab(_ modifiers: KeyModifiers) -> KeyChord { KeyChord("\t", modifiers) }
    static func `return`(_ modifiers: KeyModifiers) -> KeyChord { KeyChord("\r", modifiers) }

    /// SwiftUI's side of it. Nil when the stored key is not a single character,
    /// which only a hand-edited preference could produce.
    var keyEquivalent: KeyEquivalent? {
        guard key.count == 1, let character = key.first else { return nil }
        return KeyEquivalent(character)
    }

    /// What the row in Settings, and every `.help(…)` that names its key, show.
    var display: String { modifiers.display + Self.name(of: key) }

    // MARK: Matching a real key press

    /// Whether this is the keystroke that just happened.
    func matches(_ event: NSEvent) -> Bool {
        guard !key.isEmpty, KeyModifiers(event.modifierFlags) == modifiers else { return false }
        return Self.character(of: event) == key
    }

    /// The same, with ⇧ left out of it on both sides — for a key that means one
    /// thing forwards and the same thing backwards with ⇧ added.
    func matchesIgnoringShift(_ event: NSEvent) -> Bool {
        guard !key.isEmpty,
              KeyModifiers(event.modifierFlags).subtracting(.shift) == modifiers.subtracting(.shift)
        else { return false }
        return Self.character(of: event) == key
    }

    /// The modifiers that have to stay down for a hold-and-press shortcut to
    /// still be running — everything but ⇧, which only reverses the direction.
    var holdFlags: NSEvent.ModifierFlags { modifiers.subtracting(.shift).flags }

    /// The key of an event, in the form ``key`` is stored in. ⇧ is folded away
    /// with the lowercasing, so ⇧O and O are the same key here.
    static func character(of event: NSEvent) -> String? {
        guard let typed = event.charactersIgnoringModifiers, !typed.isEmpty else { return nil }
        return typed.lowercased()
    }

    // MARK: Names

    /// The keys that type nothing, by the character SwiftUI and AppKit both
    /// stand in for them — `KeyEquivalent.tab` is a tab, an arrow is one of the
    /// private-use codes `NSUpArrowFunctionKey` and friends name.
    private static let named: [String: String] = [
        "\t": "⇥",
        "\r": "⏎",
        "\n": "⏎",
        "\u{1b}": "⎋",
        // AppKit reports ⌫ as `NSDeleteCharacter` (0x7F) and ⌦ as a function
        // key; SwiftUI's `KeyEquivalent.delete` is a backspace (0x08). Both
        // spellings of ⌫ are here because both turn up.
        "\u{8}": "⌫",
        "\u{7f}": "⌫",
        Self.character(NSDeleteFunctionKey): "⌦",
        " ": "Space",
        Self.character(NSUpArrowFunctionKey): "↑",
        Self.character(NSDownArrowFunctionKey): "↓",
        Self.character(NSLeftArrowFunctionKey): "←",
        Self.character(NSRightArrowFunctionKey): "→",
        Self.character(NSHomeFunctionKey): "↖",
        Self.character(NSEndFunctionKey): "↘",
        Self.character(NSPageUpFunctionKey): "⇞",
        Self.character(NSPageDownFunctionKey): "⇟"
    ]

    /// AppKit names these keys with an `Int` in the private-use area.
    private static func character(_ functionKey: Int) -> String {
        guard let scalar = UnicodeScalar(UInt32(functionKey)) else { return "" }
        return String(scalar)
    }

    private static func name(of key: String) -> String {
        if let name = named[key] { return name }
        // A function key is F1…F20 rather than the character behind it.
        if let scalar = key.unicodeScalars.first,
           scalar.value >= UInt32(NSF1FunctionKey),
           scalar.value <= UInt32(NSF20FunctionKey) {
            return "F\(scalar.value - UInt32(NSF1FunctionKey) + 1)"
        }
        return key.uppercased()
    }

    /// Whether this key has to have a modifier with it.
    ///
    /// A menu key equivalent is dispatched *before* whatever has focus sees the
    /// event, so a shortcut with no modifier fires halfway through typing a
    /// comment, a commit message or a shell command. That rules out every key
    /// you type with — the letters and digits, but ⇥, ⏎, Space, ⌫ and the
    /// arrows just as much. Only the function keys, which type nothing
    /// anywhere, are safe alone.
    var needsModifier: Bool {
        guard key.count == 1, let scalar = key.unicodeScalars.first else { return false }
        let isFunctionKey = scalar.value >= UInt32(NSF1FunctionKey)
            && scalar.value <= UInt32(NSF20FunctionKey)
        return !isFunctionKey
    }
}

/// The four modifiers a shortcut can use. Its own type rather than
/// `EventModifiers`, because this one is written to disk and has to keep
/// meaning the same thing.
struct KeyModifiers: OptionSet, Hashable, Codable, Sendable {
    let rawValue: Int

    init(rawValue: Int) { self.rawValue = rawValue }

    static let command = KeyModifiers(rawValue: 1 << 0)
    static let shift = KeyModifiers(rawValue: 1 << 1)
    static let option = KeyModifiers(rawValue: 1 << 2)
    static let control = KeyModifiers(rawValue: 1 << 3)

    init(_ flags: NSEvent.ModifierFlags) {
        var result: KeyModifiers = []
        if flags.contains(.command) { result.insert(.command) }
        if flags.contains(.shift) { result.insert(.shift) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.control) { result.insert(.control) }
        self = result
    }

    var flags: NSEvent.ModifierFlags {
        var result: NSEvent.ModifierFlags = []
        if contains(.command) { result.insert(.command) }
        if contains(.shift) { result.insert(.shift) }
        if contains(.option) { result.insert(.option) }
        if contains(.control) { result.insert(.control) }
        return result
    }

    var eventModifiers: EventModifiers {
        var result: EventModifiers = []
        if contains(.command) { result.insert(.command) }
        if contains(.shift) { result.insert(.shift) }
        if contains(.option) { result.insert(.option) }
        if contains(.control) { result.insert(.control) }
        return result
    }

    /// In the order the menu bar draws them.
    var display: String {
        var result = ""
        if contains(.control) { result += "⌃" }
        if contains(.option) { result += "⌥" }
        if contains(.shift) { result += "⇧" }
        if contains(.command) { result += "⌘" }
        return result
    }
}

// MARK: - Wearing it

extension View {
    /// Binds this control to whatever key the action is set to, and to none if
    /// the user cleared it.
    ///
    /// Reading the store here rather than being handed a key is the point:
    /// `@Observable` notices the read, so rebinding a key in Settings redraws
    /// the menu item with the new one straight away.
    @ViewBuilder
    func shortcut(_ action: ShortcutAction) -> some View {
        if let chord = KeyboardShortcuts.shared.chord(for: action),
           let equivalent = chord.keyEquivalent {
            keyboardShortcut(equivalent, modifiers: chord.modifiers.eventModifiers)
        } else {
            self
        }
    }

    /// A tooltip with the action's current key in brackets after it — "Post
    /// (⌘⏎)" — and without them when the action has no key.
    @MainActor
    func shortcutHelp(_ text: String, _ action: ShortcutAction) -> some View {
        help(ShortcutAction.helpText(text, action))
    }
}

extension ShortcutAction {
    @MainActor
    static func helpText(_ text: String, _ action: ShortcutAction) -> String {
        guard let chord = KeyboardShortcuts.shared.chord(for: action) else { return text }
        return "\(text) (\(chord.display))"
    }
}
