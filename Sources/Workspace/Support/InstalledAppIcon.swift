import AppKit
import SwiftUI

/// The real icon of an app installed on this Mac, looked up through Launch
/// Services at runtime — nothing has to be shipped in our own bundle.
@MainActor
enum InstalledAppIcon {
    private static var cache: [String: NSImage?] = [:]

    /// Nil when the app is not installed.
    static func image(bundleIdentifier: String) -> NSImage? {
        if let cached = cache[bundleIdentifier] { return cached }
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
        let icon = url.map { NSWorkspace.shared.icon(forFile: $0.path) }
        cache[bundleIdentifier] = icon
        return icon
    }
}

/// A `Label` that uses an installed app's own icon, and falls back to an SF
/// Symbol when that app is not on this Mac.
struct AppIconLabel: View {
    let title: String
    let bundleIdentifier: String
    let fallbackSymbol: String

    var body: some View {
        if let icon = InstalledAppIcon.image(bundleIdentifier: bundleIdentifier) {
            Label {
                Text(title)
            } icon: {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    // Matches the height of the SF Symbols in the row.
                    .frame(width: 15, height: 15)
            }
        } else {
            Label(title, systemImage: fallbackSymbol)
        }
    }
}
