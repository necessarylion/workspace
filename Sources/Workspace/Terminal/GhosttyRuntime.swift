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

        // Ghostty wakes us whenever it has work, which under a program painting
        // at frame rate is many times per frame. One tick answers all of them,
        // so only the first wakeup of a batch pays for a hop.
        runtime.wakeup_cb = { _ in
            guard GhosttyRuntime.pendingTick.claim() else { return }
            Task { @MainActor in
                // Cleared first: a wakeup arriving during the tick is about
                // work this tick has not seen, and has to schedule its own.
                GhosttyRuntime.pendingTick.clear()
                GhosttyRuntime.shared.tick()
            }
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
        // The user's own Ghostty config applies: keybindings, shell integration,
        // everything it says that we do not.
        ghostty_config_load_default_files(config)
        // …except the colours, which are the app's theme, and the font when
        // Settings overrides it. libghostty only reads settings from files, so
        // write a short one.
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
        let appearance = AppearanceSettings.shared
        // The theme picked in Settings, all sixteen ANSI slots of it: a shell
        // and a file are the same pane in the same app, and two colour schemes
        // across one window is the thing this replaced.
        var lines = TerminalPalette.configLines(for: appearance.palette)

        // `terminalFace` is the face code is shown in, so a shell opens in the
        // one a file opens in. Nil only when that is not installed — libghostty
        // takes a name and cannot be handed the system face under Apple's
        // private one, so there it keeps its own default.
        if let face = appearance.terminalFace {
            // `font-family` is a *list* in ghostty: naming one appends it as a
            // fallback behind whatever the user's own config named, which would
            // leave their face drawing the terminal and ours only filling in
            // the glyphs it lacked. `""` is what ghostty documents as the way
            // to clear a repeated value before setting it, so the face chosen
            // here is the one in front. The three styles are cleared with it:
            // with none of them named, ghostty looks for the bold and the
            // italic inside the family in front, which is the point.
            for key in ["font-family", "font-family-bold", "font-family-italic", "font-family-bold-italic"] {
                lines.append("\(key) = \"\"")
            }
            lines.append("font-family = \(face)")
        }
        lines.append("font-size = \(appearance.terminalFontSize)")

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
        // Gathered rather than hopped one at a time; see ``pendingRenders``.
        case GHOSTTY_ACTION_RENDER:
            guard pendingRenders.add(surfaceBits) else { return true }
            Task { @MainActor in
                for bits in pendingRenders.drain() {
                    guard let surface = UnsafeMutableRawPointer(bitPattern: bits),
                          let userdata = ghostty_surface_userdata(surface) else { continue }
                    Unmanaged<GhosttySurfaceView>.fromOpaque(userdata)
                        .takeUnretainedValue()
                        .needsDisplay = true
                }
            }
            return true

        case GHOSTTY_ACTION_SET_TITLE:
            guard let titlePtr = action.action.set_title.title else { return false }
            let title = String(cString: titlePtr)
            onView(surfaceBits) { view in view.onTitleChange?(title) }
            return true

        case GHOSTTY_ACTION_RING_BELL:
            Task { @MainActor in NSSound.beep() }
            onView(surfaceBits) { view in view.onBell?() }
            return true

        // OSC 9 / OSC 777 — a program asking the desktop to say something.
        // The strings belong to ghostty and are only valid for the length of
        // this call, so they are copied here rather than on the way over.
        case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
            let notification = action.action.desktop_notification
            let title = notification.title.map { String(cString: $0) }
            let body = notification.body.map { String(cString: $0) } ?? ""
            onView(surfaceBits) { view in view.onDesktopNotification?(title, body) }
            return true

        // Ghostty finds the links itself and draws the underline itself; what
        // it cannot do from in there is change the pointer over one.
        case GHOSTTY_ACTION_MOUSE_SHAPE:
            let shape = action.action.mouse_shape.rawValue
            onView(surfaceBits) { view in view.setMouseShape(shape) }
            return true

        // An empty URL is how ghostty says the pointer has left the link.
        case GHOSTTY_ACTION_MOUSE_OVER_LINK:
            let isOver = action.action.mouse_over_link.len > 0
            onView(surfaceBits) { view in view.setOverLink(isOver) }
            return true

        // ⌘-click on a link. The terminal's contents are ghostty's alone, so
        // this is the only way a URL in it ever reaches a browser.
        case GHOSTTY_ACTION_OPEN_URL:
            let opened = action.action.open_url
            guard let address = opened.url else { return false }
            // Counted, not NUL-terminated, and only ours for this call.
            let text = String(
                decoding: UnsafeRawBufferPointer(start: address, count: Int(opened.len)),
                as: UTF8.self
            )
            guard let url = URL(string: text) else { return false }
            Task { @MainActor in NSWorkspace.shared.open(url) }
            return true

        default:
            // Tabs, splits, fullscreen … are this app's own concern, not
            // ghostty's. Report them unhandled.
            return false
        }
    }

    // MARK: - Coalescing

    /// The surfaces waiting to be marked for redraw.
    ///
    /// Ghostty asks to render whenever a surface is dirty, and a shell running
    /// a spinner — every `claude` mid-turn — is dirty every frame, whether or
    /// not anyone has that tab on screen. A hop per request meant the cost of
    /// a window grew with each terminal left running in it, which is the shape
    /// of an app that gets slower the longer it is open. The requests are
    /// gathered on ghostty's own thread instead, and one hop marks everything
    /// that arrived while it was waiting its turn.
    private nonisolated static let pendingRenders = RenderQueue()
    /// The same for `wakeup_cb`, which has nothing to gather.
    private nonisolated static let pendingTick = Latch()

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

/// A one-shot flag shared across threads: the first caller to ``claim`` owes
/// the main-actor hop, and everyone arriving behind it is already covered by
/// the hop that one is about to make.
private final class Latch: @unchecked Sendable {
    private let lock = NSLock()
    private var isSet = false

    /// True when this caller is the one that has to schedule the work.
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isSet else { return false }
        isSet = true
        return true
    }

    /// Called at the *start* of the scheduled work, so anything arriving while
    /// it runs schedules a fresh pass rather than being swallowed by this one.
    func clear() {
        lock.lock()
        isSet = false
        lock.unlock()
    }
}

/// The surfaces that have asked to be redrawn since the last drain, and one
/// latch saying whether a drain is already on its way.
private final class RenderQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: Set<Int> = []
    private var isScheduled = false

    /// Records a surface, and returns true only for the request that has to
    /// schedule the drain.
    func add(_ surfaceBits: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        pending.insert(surfaceBits)
        guard !isScheduled else { return false }
        isScheduled = true
        return true
    }

    /// Everything that arrived since the last drain. Taking the batch and
    /// releasing the latch is one step, so a request landing mid-drain is
    /// either in this batch or schedules the next one — never neither.
    func drain() -> Set<Int> {
        lock.lock()
        defer { lock.unlock() }
        isScheduled = false
        let batch = pending
        pending.removeAll(keepingCapacity: true)
        return batch
    }
}
