import AppKit
import GhosttyKit

/// One ghostty terminal surface: a Metal-backed NSView that forwards size,
/// focus, keyboard and mouse to libghostty, which renders into our layer and
/// runs the shell itself.
final class GhosttySurfaceView: NSView {
    /// The ghostty surface handle. `nonisolated(unsafe)` so `deinit` can free
    /// it; everything else touches it from the main actor only.
    nonisolated(unsafe) private(set) var surface: ghostty_surface_t?

    var onTitleChange: ((String) -> Void)?
    var onClose: (() -> Void)?

    private var pendingStart: (directory: URL, initialInput: String?)?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 480))
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    deinit {
        if let surface {
            ghostty_surface_free(surface)
        }
    }

    // Ghostty renders with Metal straight into our backing layer.
    override func makeBackingLayer() -> CALayer { CAMetalLayer() }
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        guard let surface else { return }
        ghostty_surface_draw(surface)
    }

    // MARK: - Lifecycle

    /// Queues the shell start; the surface is created once the view is in a
    /// window (the content scale is unknown before that).
    func start(directory: URL, initialInput: String?) {
        pendingStart = (directory, initialInput)
        createSurfaceIfReady()
    }

    /// Whether the shell is up: before this, `send` has nowhere to go.
    var isLive: Bool { surface != nil }

    func close() {
        guard let surface else { return }
        ghostty_surface_free(surface)
        self.surface = nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        createSurfaceIfReady()
        if window != nil, surface != nil {
            updateScale()
            updateSurfaceSize()
        }
    }

    private func createSurfaceIfReady() {
        guard surface == nil,
              let pending = pendingStart,
              window != nil,
              let app = GhosttyRuntime.shared.app else { return }
        pendingStart = nil

        var config = ghostty_surface_config_new()
        config.platform_tag = GHOSTTY_PLATFORM_MACOS
        config.platform = ghostty_platform_u(
            macos: ghostty_platform_macos_s(nsview: Unmanaged.passUnretained(self).toOpaque())
        )
        config.userdata = Unmanaged.passUnretained(self).toOpaque()
        config.scale_factor = Double(window?.backingScaleFactor ?? 2)

        pending.directory.path.withCString { directory in
            config.working_directory = directory
            if let input = pending.initialInput {
                input.withCString { inputPtr in
                    config.initial_input = inputPtr
                    surface = ghostty_surface_new(app, &config)
                }
            } else {
                surface = ghostty_surface_new(app, &config)
            }
        }

        if surface != nil {
            updateSurfaceSize()
            needsDisplay = true
        }
    }

    /// Types text into the shell. Ghostty treats this as a paste, so under
    /// bracketed paste a trailing newline does NOT run the command — call
    /// `pressEnter()` for that.
    func send(_ text: String) {
        guard let surface else { return }
        text.withCString { ptr in
            ghostty_surface_text(surface, ptr, UInt(text.utf8.count))
        }
    }

    /// A real Return keypress — the only thing shells accept as "run it".
    func pressEnter() {
        guard let surface else { return }
        var key = ghostty_input_key_s()
        key.mods = ghostty_input_mods_e(rawValue: GHOSTTY_MODS_NONE.rawValue)
        key.consumed_mods = ghostty_input_mods_e(rawValue: GHOSTTY_MODS_NONE.rawValue)
        key.keycode = 36 // kVK_Return
        key.unshifted_codepoint = 0x0D
        key.composing = false
        key.action = GHOSTTY_ACTION_PRESS
        _ = ghostty_surface_key(surface, key)
        key.action = GHOSTTY_ACTION_RELEASE
        _ = ghostty_surface_key(surface, key)
    }

    // MARK: - Geometry

    override func layout() {
        super.layout()
        updateSurfaceSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateScale()
        updateSurfaceSize()
    }

    private func updateScale() {
        guard let surface, let scale = window?.backingScaleFactor else { return }
        ghostty_surface_set_content_scale(surface, scale, scale)
    }

    private func updateSurfaceSize() {
        guard let surface else { return }
        let backing = convertToBacking(bounds.size)
        ghostty_surface_set_size(
            surface,
            UInt32(max(backing.width, 1)),
            UInt32(max(backing.height, 1))
        )
    }

    // MARK: - Focus

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted, let surface {
            ghostty_surface_set_focus(surface, true)
        }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned, let surface {
            ghostty_surface_set_focus(surface, false)
        }
        return resigned
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        guard surface != nil else { return }
        _ = forwardKey(event, action: event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS)
    }

    override func keyUp(with event: NSEvent) {
        guard surface != nil else { return }
        _ = forwardKey(event, action: GHOSTTY_ACTION_RELEASE)
    }

    /// Only the clipboard combos are swallowed here; every other ⌘-shortcut
    /// belongs to the app's menus.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard surface != nil,
              window?.firstResponder === self,
              event.modifierFlags.contains(.command),
              let characters = event.charactersIgnoringModifiers,
              characters == "c" || characters == "v" else { return false }
        return forwardKey(event, action: GHOSTTY_ACTION_PRESS)
    }

    @discardableResult
    private func forwardKey(_ event: NSEvent, action: ghostty_input_action_e) -> Bool {
        guard let surface else { return false }

        var key = ghostty_input_key_s()
        key.action = action
        key.mods = Self.mods(from: event.modifierFlags)
        key.consumed_mods = ghostty_input_mods_e(rawValue: GHOSTTY_MODS_NONE.rawValue)
        key.keycode = UInt32(event.keyCode)
        key.composing = false
        key.unshifted_codepoint = 0
        if let unshifted = event.characters(byApplyingModifiers: []) ?? event.charactersIgnoringModifiers,
           let scalar = unshifted.unicodeScalars.first {
            key.unshifted_codepoint = scalar.value
        }

        // Pass translated text only when it is actual text. Control sequences
        // (⌃C, arrows, return, …) are encoded by ghostty from keycode + mods;
        // handing it macOS's control characters as "text" would double up.
        let text = event.characters ?? ""
        let isText = action != GHOSTTY_ACTION_RELEASE
            && !event.modifierFlags.contains(.command)
            && !text.isEmpty
            && text.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7F }

        if isText {
            // The translation consumed shift/alt to produce the character.
            key.consumed_mods = ghostty_surface_key_translation_mods(surface, key.mods)
            return text.withCString { ptr in
                key.text = ptr
                return ghostty_surface_key(surface, key)
            }
        }
        return ghostty_surface_key(surface, key)
    }

    private static func mods(from flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var mods = GHOSTTY_MODS_NONE.rawValue
        if flags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { mods |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { mods |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { mods |= GHOSTTY_MODS_CAPS.rawValue }
        return ghostty_input_mods_e(rawValue: mods)
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        button(GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, event)
    }
    override func mouseUp(with event: NSEvent) { button(GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, event) }
    override func rightMouseDown(with event: NSEvent) { button(GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, event) }
    override func rightMouseUp(with event: NSEvent) { button(GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT, event) }
    override func otherMouseDown(with event: NSEvent) { button(GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_MIDDLE, event) }
    override func otherMouseUp(with event: NSEvent) { button(GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_MIDDLE, event) }

    private func button(
        _ state: ghostty_input_mouse_state_e,
        _ which: ghostty_input_mouse_button_e,
        _ event: NSEvent
    ) {
        guard let surface else { return }
        _ = ghostty_surface_mouse_button(surface, state, which, Self.mods(from: event.modifierFlags))
    }

    override func mouseMoved(with event: NSEvent) { reportMouse(event) }
    override func mouseDragged(with event: NSEvent) { reportMouse(event) }
    override func rightMouseDragged(with event: NSEvent) { reportMouse(event) }
    override func otherMouseDragged(with event: NSEvent) { reportMouse(event) }

    override func mouseExited(with event: NSEvent) {
        guard let surface else { return }
        // Negative position means "the pointer left".
        ghostty_surface_mouse_pos(surface, -1, -1, Self.mods(from: event.modifierFlags))
    }

    private func reportMouse(_ event: NSEvent) {
        guard let surface else { return }
        let position = convert(event.locationInWindow, from: nil)
        // Ghostty's origin is the top-left corner.
        ghostty_surface_mouse_pos(
            surface,
            position.x,
            frame.height - position.y,
            Self.mods(from: event.modifierFlags)
        )
    }

    override func scrollWheel(with event: NSEvent) {
        guard let surface else { return }
        var x = event.scrollingDeltaX
        var y = event.scrollingDeltaY
        if !event.hasPreciseScrollingDeltas {
            x *= 10
            y *= 10
        }

        // Packed struct: bit 0 precision, bits 1-3 momentum phase.
        var scrollMods: Int32 = event.hasPreciseScrollingDeltas ? 1 : 0
        scrollMods |= Self.momentum(event.momentumPhase) << 1

        ghostty_surface_mouse_scroll(surface, x, y, scrollMods)
    }

    private static func momentum(_ phase: NSEvent.Phase) -> Int32 {
        switch phase {
        case .began: 1
        case .stationary: 2
        case .changed: 3
        case .ended: 4
        case .cancelled: 5
        case .mayBegin: 6
        default: 0
        }
    }

    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking {
            removeTrackingArea(tracking)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .inVisibleRect, .activeInKeyWindow],
            owner: self
        )
        addTrackingArea(area)
        tracking = area
    }
}
