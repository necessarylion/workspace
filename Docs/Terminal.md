# Terminal: libghostty

The embedded terminal is [libghostty](https://github.com/ghostty-org/ghostty) —
the same engine as the Ghostty app, linked as a static library. SwiftTerm is
gone. The user's own Ghostty config applies inside this app too, because the
runtime loads the default config files — everything in it that we do not
override ourselves. **The colours and the font we do**: a shell is drawn in the
theme picked in Settings and in the face code is shown in, since a terminal
with a scheme of its own made one window look like two apps. See
`Themes/TerminalPalette.swift`, which turns the editor's palette into the
sixteen ANSI slots a terminal needs.

## The pieces

- **the `GhosttyKit` package product** — libghostty as a prebuilt universal
  (arm64 + x86_64) static xcframework, downloaded and checksum-verified by
  SwiftPM during resolution, so no Zig toolchain and no vendored binary are
  needed. `Package.swift` also lists the frameworks and libs the archive pulls
  in (Metal, CoreText, Carbon, libc++, …). The product is a one-line Swift
  target that does `@_exported import libghostty`, which is why `import
  GhosttyKit` still yields the raw C API.
- **`Resources/ghostty-share/`** — ghostty's runtime resources: the terminfo
  entries for `TERM=xterm-ghostty`, the shell integration scripts, and one
  theme. They are not part of the xcframework, so they are checked in;
  `Scripts/bundle.sh` copies them into the app bundle and `GhosttyRuntime`
  points `GHOSTTY_RESOURCES_DIR` there before `ghostty_init`. Upstream ships
  590 themes (2.3 MB); only `Ghostty Default Style Dark` is kept, which is why
  the whole directory is 84 KB. The consequence: a `theme = …` line in the
  user's own ghostty config no longer resolves — ghostty logs it and falls
  back to its built-in colours. It would make no difference now anyway: the
  app writes every colour on top of whatever that file says.
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

## Where the binary comes from

Upstream ghostty ships no reusable framework. Its only release is `tip`, and
the one xcframework there — `ghostty-vt.xcframework` — is the VT parser alone:
it has no `ghostty_init`, no `ghostty_app_new`, no `ghostty_surface_new`, so it
cannot back this terminal. The prebuilt full library therefore comes from
[libghostty-spm](https://github.com/Lakr233/libghostty-spm) (MIT), which
rebuilds upstream at a pinned commit and publishes a universal
arm64 + x86_64 xcframework. It is depended on with `exact:`, and its own
manifest pins the artifact by SHA-256, so the binary cannot change under us.

To move to a newer libghostty, bump the `exact:` version, then check
`ghostty.h` for API changes — the struct layouts in
`GhosttyRuntime`/`GhosttySurfaceView` must match.

If depending on a third-party mirror ever becomes uncomfortable, the escape
hatch is to build it yourself:

```sh
brew install zig                 # 0.16.x
git clone --depth 1 https://github.com/ghostty-org/ghostty.git
cd ghostty
zig build -Doptimize=ReleaseFast -Dxcframework-target=universal -Demit-macos-app=false
# → macos/GhosttyKit.xcframework, zig-out/share/{ghostty,terminfo}
```

The `share` output is also where `Resources/ghostty-share/` is refreshed from.

Two things to know before checking such a build into a repository: the iOS
slices are dead weight here and can be deleted, and the universal macOS
archive is **258 MB** — past GitHub's 100 MB hard limit for a single file.
`strip -S` takes it to 49 MB without affecting linking, which is what makes
vendoring it feasible at all.

## Not done (yet)

- IME / dead-key composition (`ghostty_surface_preedit`) — typing accented
  characters via long-press or CJK input goes through the plain text path.
- Mouse cursor shape changes (`GHOSTTY_ACTION_MOUSE_SHAPE` is ignored).
- Splits inside one tab (we use our own tab bar instead).
