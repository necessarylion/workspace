import AppKit
import SwiftUI

/// Settings → Shortcuts: every key the app binds for itself, and a way to
/// change any of them.
///
/// One key monitor serves the whole list rather than one per row: while a row
/// is recording it takes *every* keystroke in this window, which is the only
/// way ⌘W or ⌘Q can be recorded rather than obeyed. ⎋ stops recording and
/// ⌫ clears the key, so both stay reachable.
struct ShortcutSettings: View {
    private var shortcuts: KeyboardShortcuts { .shared }

    /// The row waiting for a keystroke, if any.
    @State private var recording: ShortcutAction?
    /// What is held down right now, drawn in the recording row so the chord
    /// builds up under the pointer instead of appearing all at once.
    @State private var held: KeyModifiers = []
    /// Why the last keystroke was not taken — cleared as soon as one is.
    @State private var refused: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(ShortcutGroup.allCases) { group in
                        GroupHeader(title: group.title)
                        ForEach(group.actions) { action in
                            ShortcutRow(
                                action: action,
                                chord: shortcuts.chord(for: action),
                                isRecording: recording == action,
                                held: recording == action ? held : [],
                                isCustomised: shortcuts.isCustomised(action),
                                conflicts: shortcuts.conflicts(with: action),
                                record: { startRecording(action) },
                                clear: { shortcuts.set(nil, for: action) },
                                restore: { shortcuts.reset(action) }
                            )
                            if action != group.actions.last {
                                Divider().padding(.leading, 16)
                            }
                        }
                    }
                }
                .padding(.bottom, 8)
            }

            Divider()
            footer
        }
        .onWindowKeyEvent(matching: [.keyDown, .flagsChanged]) { event, window in
            handle(event, in: window)
        }
        // Clicking away from a half-finished recording ends it, rather than
        // leaving a row armed for a key pressed minutes later.
        .onDisappear { stopRecording() }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Keyboard Shortcuts")
                    .font(.headline)
                Text("Click a key to record a new one. ⎋ leaves it as it was, ⌫ takes the key away.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(16)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let refused {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text(refused)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Only the keys the app binds itself are here — the editor's ⌘F, the completion list's ⌃Space and everything macOS owns stay as they are.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if shortcuts.isCustomised {
                Button("Restore Defaults") {
                    stopRecording()
                    shortcuts.restoreDefaults()
                }
                .controlSize(.small)
                .pointerCursor()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Recording

    private func startRecording(_ action: ShortcutAction) {
        refused = nil
        held = []
        recording = recording == action ? nil : action
    }

    private func stopRecording() {
        recording = nil
        held = []
    }

    /// Everything typed while a row is armed belongs to that row. Returns true
    /// for the keys it swallows, which — deliberately — is all of them: a
    /// recorder that let ⌘W through could never record ⌘W.
    private func handle(_ event: NSEvent, in window: NSWindow) -> Bool {
        guard let action = recording, window.attachedSheet == nil else { return false }

        if event.type == .flagsChanged {
            held = KeyModifiers(event.modifierFlags)
            return true
        }

        // ⎋ on its own gets out; ⌥⎋ and the rest are recordable like any key.
        if event.isEscape {
            stopRecording()
            return true
        }

        let modifiers = KeyModifiers(event.modifierFlags)
        guard let key = KeyChord.character(of: event) else { return true }

        // ⌫ with nothing held is how a key is taken away, the same as in
        // System Settings.
        if modifiers.isEmpty, key == "\u{7f}" || key == "\u{8}" {
            shortcuts.set(nil, for: action)
            refused = nil
            stopRecording()
            return true
        }

        let chord = KeyChord(key, modifiers)
        // A bare letter would fire while you were typing one, because a menu
        // key equivalent is dispatched before anything with focus sees it.
        if chord.needsModifier, modifiers.isEmpty {
            refused = "\(chord.display) needs ⌘, ⌃, ⌥ or ⇧ with it — on its own it would fire while you were typing."
            return true
        }

        shortcuts.set(chord, for: action)
        refused = nil
        stopRecording()
        return true
    }
}

/// The section titles down the list — quieter than a `Form` section, which
/// would box each group and cost the vertical room this many rows need.
private struct GroupHeader: View {
    let title: String

    var body: some View {
        HStack {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 6)
    }
}

/// One command: what it does, the key it is on, and the two buttons that
/// change it.
private struct ShortcutRow: View {
    let action: ShortcutAction
    let chord: KeyChord?
    let isRecording: Bool
    let held: KeyModifiers
    let isCustomised: Bool
    let conflicts: [ShortcutAction]
    let record: () -> Void
    let clear: () -> Void
    let restore: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(action.title)
                        .font(.body.weight(.medium))
                    if isCustomised {
                        Pill(text: "changed", color: .blue)
                    }
                }
                Text(action.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !conflicts.isEmpty {
                    // Not refused, only pointed out: which of the two should
                    // move is the user's decision, and they may be halfway
                    // through swapping a pair over.
                    Text("Also on \(conflicts.map(\.title).joined(separator: ", ")) — only one of them will fire.")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                KeyCap(chord: chord, isRecording: isRecording, held: held)
                    .onTapGesture(perform: record)
                    .pointerCursor()

                Button(action: isCustomised ? restore : clear) {
                    Image(systemName: isCustomised ? "arrow.uturn.backward" : "xmark")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .frame(width: 18)
                .help(isCustomised ? "Put the app's own key back" : "Leave this command with no key")
                .disabled(!isCustomised && chord == nil)
                .pointerCursor(isCustomised || chord != nil)
            }
            .padding(.top, 1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .contentShape(.rect)
    }
}

/// The key itself, drawn as a key.
private struct KeyCap: View {
    let chord: KeyChord?
    let isRecording: Bool
    let held: KeyModifiers

    var body: some View {
        Text(label)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(foreground)
            .monospacedDigit()
            .lineLimit(1)
            .frame(minWidth: 74)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(background, in: .rect(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(
                        isRecording ? Color.accentColor : Color.primary.opacity(0.14),
                        lineWidth: isRecording ? 1.5 : 1
                    )
            }
    }

    /// While recording, the modifiers already down are shown on their own, so
    /// holding ⇧⌘ before choosing a letter looks like progress rather than
    /// like nothing happening.
    private var label: String {
        if isRecording {
            return held.isEmpty ? "Press a key…" : held.display
        }
        return chord?.display ?? "None"
    }

    private var foreground: Color {
        if isRecording { return .accentColor }
        return chord == nil ? .secondary : .primary
    }

    private var background: Color {
        isRecording ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.06)
    }
}
