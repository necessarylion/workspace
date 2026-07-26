import AppKit
import GhosttyKit

/// The embedded libghostty application — one per process.
///
/// Owns the `ghostty_app_t`, its configuration and the runtime callbacks.
/// Individual shells are `GhosttySurfaceView`s, one per terminal tab.
///
/// Threading: ghostty calls `wakeup` and `render` from its own threads; every
/// callback therefore either hops to the main actor or, when ghostty
/// guarantees the call happens during `ghostty_app_tick` (which we only run
/// on the main thread), asserts isolation.
@MainActor
final class GhosttyRuntime {
    static let shared = GhosttyRuntime()
    /// Whether anything has ever asked for `shared`. Settings can then reload
    /// the configuration without booting ghostty for a terminal nobody opened.
    private static var isStarted = false

    private(set) var app: ghostty_app_t?
    private var config: ghostty_config_t?
    /// Every live surface, so a configuration change reaches the shells that
    /// are already running. Weak: a closed tab's view just leaves the table.
    private let surfaces = NSHashTable<GhosttySurfaceView>.weakObjects()

    private init() {
        Self.isStarted = true

        // Terminfo and shell integration are copied into the bundle by
        // Scripts/bundle.sh; ghostty resolves both from this variable.
        if let resources = Bundle.main.resourcePath.map({ $0 + "/ghostty" }),
           FileManager.default.fileExists(atPath: resources) {
            setenv("GHOSTTY_RESOURCES_DIR", resources, 1)
        }

        guard ghostty_init(0, nil) == 0 else {
            assertionFailure("ghostty_init failed")
            return
        }

        guard let config = Self.makeConfig() else { return }
        self.config = config

        var runtime = ghostty_runtime_config_s()
        runtime.userdata = nil
        runtime.supports_selection_clipboard = false

        runtime.wakeup_cb = { _ in
            Task { @MainActor in GhosttyRuntime.shared.tick() }
        }

        runtime.action_cb = { _, target, action in
            GhosttyRuntime.handle(action: action, on: target)
        }

        // Paste: hand the pasteboard string back to the requesting surface.
        runtime.read_clipboard_cb = { userdata, location, state in
            guard let userdata, location == GHOSTTY_CLIPBOARD_STANDARD else { return false }
            MainActor.assumeIsolated {
                let view = Unmanaged<GhosttySurfaceView>.fromOpaque(userdata).takeUnretainedValue()
                guard let surface = view.surface else { return }
                let string = NSPasteboard.general.string(forType: .string) ?? ""
                string.withCString { ptr in
                    ghostty_surface_complete_clipboard_request(surface, ptr, state, false)
                }
            }
            return true
        }

        // Ghostty wants confirmation (e.g. paste with control characters).
        // We are a dev tool: confirm and move on.
        runtime.confirm_read_clipboard_cb = { userdata, string, state, _ in
            guard let userdata else { return }
            MainActor.assumeIsolated {
                let view = Unmanaged<GhosttySurfaceView>.fromOpaque(userdata).takeUnretainedValue()
                guard let surface = view.surface else { return }
                ghostty_surface_complete_clipboard_request(surface, string, state, true)
            }
        }

        // Copy: take the text/plain representation.
        runtime.write_clipboard_cb = { _, location, contents, count, _ in
            guard location == GHOSTTY_CLIPBOARD_STANDARD, let contents else { return }
            var text: String?
            for index in 0..<count {
                let content = contents[index]
                guard let mime = content.mime, let data = content.data else { continue }
                if String(cString: mime).hasPrefix("text/plain") {
                    text = String(cString: data)
                }
            }
            guard let text else { return }
            MainActor.assumeIsolated {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        }

        // The shell exited (or a close binding fired).
        runtime.close_surface_cb = { userdata, _ in
            guard let userdata else { return }
            let bits = Int(bitPattern: userdata)
            Task { @MainActor in
                guard let raw = UnsafeMutableRawPointer(bitPattern: bits) else { return }
                let view = Unmanaged<GhosttySurfaceView>.fromOpaque(raw).takeUnretainedValue()
                view.onClose?()
            }
        }

        app = ghostty_app_new(&runtime, config)
        tick()
    }

    /// The user's own Ghostty config, with our own settings on top.
    private static func makeConfig() -> ghostty_config_t? {
        guard let config = ghostty_config_new() else { return nil }
        // The user's own Ghostty config applies: theme, font, everything.
        ghostty_config_load_default_files(config)
        // …except the background, which has to match the app's chrome, and the
        // font when Settings overrides it. libghostty only reads settings from
        // files, so write a short one.
        if let overrides = writeOverrideConfig() {
            ghostty_config_load_file(config, overrides)
        }
        ghostty_config_finalize(config)
        return config
    }

    /// Writes the settings we impose on top of the user's config and returns
    /// its path, or nil if it could not be written.
    private static func writeOverrideConfig() -> String? {
        let path = NSTemporaryDirectory() + "workspace-ghostty-overrides.conf"
        var lines = ["background = \(AppColors.terminalBackgroundHex)"]

        let appearance = AppearanceSettings.shared
        if appearance.overridesTerminalFont {
            if let face = appearance.terminalFontName, AppearanceSettings.isInstalled(face) {
                lines.append("font-family = \(face)")
            }
            lines.append("font-size = \(appearance.terminalFontSize)")
        }

        do {
            try lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
            return path
        } catch {
            return nil
        }
    }

    /// Re-reads the configuration and hands it to every shell already running.
    /// Does nothing before the first terminal — there is no ghostty yet, and
    /// starting one just to change a font would be a strange thing to do.
    static func applyConfigurationIfRunning() {
        guard isStarted else { return }
        shared.applyConfiguration()
    }

    private func applyConfiguration() {
        guard let app, let config = Self.makeConfig() else { return }
        let previous = self.config
        self.config = config

        ghostty_app_update_config(app, config)
        for view in surfaces.allObjects {
            view.updateConfig(config)
        }
        // Only once nothing points at it any more.
        if let previous {
            ghostty_config_free(previous)
        }
        tick()
    }

    /// Called by a surface once its shell exists, so later configuration
    /// changes reach it.
    func register(_ view: GhosttySurfaceView) {
        surfaces.add(view)
    }

    func tick() {
        guard let app else { return }
        ghostty_app_tick(app)
    }

    // MARK: - Actions

    /// Runs on whatever thread ghostty called us from — extract plain values
    /// first, then hop to the main actor for anything that touches a view.
    private nonisolated static func handle(
        action: ghostty_action_s,
        on target: ghostty_target_s
    ) -> Bool {
        guard target.tag == GHOSTTY_TARGET_SURFACE, let surface = target.target.surface else {
            return false
        }
        let surfaceBits = Int(bitPattern: surface)

        switch action.tag {
        case GHOSTTY_ACTION_RENDER:
            onView(surfaceBits) { view in view.needsDisplay = true }
            return true

        case GHOSTTY_ACTION_SET_TITLE:
            guard let titlePtr = action.action.set_title.title else { return false }
            let title = String(cString: titlePtr)
            onView(surfaceBits) { view in view.onTitleChange?(title) }
            return true

        case GHOSTTY_ACTION_RING_BELL:
            Task { @MainActor in NSSound.beep() }
            return true

        default:
            // Tabs, splits, fullscreen … are this app's own concern, not
            // ghostty's. Report them unhandled.
            return false
        }
    }

    /// Finds the view that owns a surface and runs `body` on the main actor.
    private nonisolated static func onView(
        _ surfaceBits: Int,
        _ body: @escaping @MainActor (GhosttySurfaceView) -> Void
    ) {
        Task { @MainActor in
            guard let surface = UnsafeMutableRawPointer(bitPattern: surfaceBits),
                  let userdata = ghostty_surface_userdata(surface) else { return }
            body(Unmanaged<GhosttySurfaceView>.fromOpaque(userdata).takeUnretainedValue())
        }
    }
}
