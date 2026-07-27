import AppKit

/// Opening ⌘, from code.
///
/// SwiftUI's own way in is `SettingsLink`, which is a *view* — fine for the
/// gear in the sidebar, no use to a menu item that has to run a check and pick
/// a tab before the window appears. The app menu's own Settings item is an
/// action on the responder chain, so this sends the same one; the name changed
/// with macOS 14, and both are tried because neither is worth crashing over.
enum SettingsWindow {
    /// Opens Settings and asks it for the Updates tab.
    @MainActor
    static func showUpdates() {
        AppUpdater.shared.requestUpdatesTab()
        open()
    }

    @MainActor
    static func open() {
        NSApp.activate(ignoringOtherApps: true)
        for name in ["showSettingsWindow:", "showPreferencesWindow:"] {
            if NSApp.sendAction(Selector((name)), to: nil, from: nil) { return }
        }
    }
}
