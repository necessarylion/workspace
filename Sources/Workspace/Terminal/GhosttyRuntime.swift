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

    private(set) var app: ghostty_app_t?
    private var config: ghostty_config_t?

    private init() {
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

        guard let config = ghostty_config_new() else { return }
        // The user's own Ghostty config applies: theme, font, everything.
        ghostty_config_load_default_files(config)
        ghostty_config_finalize(config)
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
