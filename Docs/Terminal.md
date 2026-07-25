# Terminal: libghostty

The embedded terminal is [libghostty](https://github.com/ghostty-org/ghostty) —
the same engine as the Ghostty app, linked as a static library. SwiftTerm is
gone. The user's own Ghostty config (theme, font, keybinds) applies inside
this app too, because the runtime loads the default config files.

## The pieces

- **`.deps/GhosttyKit.xcframework`** — libghostty built with
  `zig build -Doptimize=ReleaseFast -Dxcframework-target=native` (Zig 0.16),
  vendored so the app builds without a Zig toolchain. Linked via a
  `.binaryTarget` in `Package.swift`, plus the frameworks/libs it needs
  (Metal, CoreText, Carbon, libc++, …).
- **`.deps/ghostty-share/`** — ghostty's runtime resources (terminfo for
  `TERM=xterm-ghostty`, shell integration). `Scripts/bundle.sh` copies them
  into the app bundle; `GhosttyRuntime` points `GHOSTTY_RESOURCES_DIR` there
  before `ghostty_init`.
- **`Terminal/GhosttyRuntime.swift`** — the single `ghostty_app_t`: config
  loading, `ghostty_app_tick` scheduling (wakeup callback → main actor), and
  the runtime callbacks: clipboard read/write, paste confirmation, close
  requests, and actions (render → `needsDisplay`, set-title, bell).
- **`Terminal/GhosttySurfaceView.swift`** — one `NSView` per shell, backed by
  a `CAMetalLayer` that ghostty renders into. Forwards resize (pixel size +
  content scale), focus, keys (with the text/keycode split ghostty expects),
  mouse buttons/movement/scroll and tracking areas. `send(_:)` pastes;
  `pressEnter()` synthesizes a real Return keypress.
- **`Models/TerminalSession.swift`** — the app-facing type, same narrow API
  as before: `startIfNeeded(runningCommand:)`, `send(_:)`, `terminate()`.
  Tab titles update live (ghostty reports OSC titles), and when the shell
  exits the tab closes itself (`onExit` → `WorkspaceStore.closeTerminalTab`).

## Gotchas learned the hard way

- `ghostty_surface_text` is a **paste** (`completeClipboardPaste` in core).
  Under bracketed paste, a pasted `\n` never executes a command — that is why
  `TerminalSession.send` turns a trailing newline into `pressEnter()`, a
  synthesized Return key event (keycode 36).
- The surface can only be created once the view is in a window (the backing
  scale factor is needed), so `start(...)` queues and
  `viewDidMoveToWindow` finishes the job.
- Control keys (⌃C, arrows, Return) must NOT be passed as `text` — ghostty
  encodes them from keycode + mods; macOS's control characters as text would
  double them up. Only printable translations are passed as text.
- `⌘C`/`⌘V` are intercepted in `performKeyEquivalent` and forwarded to
  ghostty (whose default keybinds do copy/paste through our clipboard
  callbacks). Every other ⌘-shortcut falls through to the app's menus.

## Rebuilding the framework

```sh
brew install zig                 # 0.16.x
git clone --depth 1 https://github.com/ghostty-org/ghostty.git
cd ghostty
zig build -Doptimize=ReleaseFast -Dxcframework-target=native
# → macos/GhosttyKit.xcframework, zig-out/share/{ghostty,terminfo}
```

Copy the xcframework over `.deps/GhosttyKit.xcframework` and the two share
dirs into `.deps/ghostty-share/`, then check `ghostty.h` for API changes —
the struct layouts in `GhosttyRuntime`/`GhosttySurfaceView` must match.

## Not done (yet)

- IME / dead-key composition (`ghostty_surface_preedit`) — typing accented
  characters via long-press or CJK input goes through the plain text path.
- Mouse cursor shape changes (`GHOSTTY_ACTION_MOUSE_SHAPE` is ignored).
- Splits inside one tab (we use our own tab bar instead).
