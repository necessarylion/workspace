import AppKit
import SwiftUI

/// The one place the app decides what "added", "changed" and "gone" look like.
///
/// Three places say it — the file tree colours a row, the editor's gutter draws a
/// stripe beside a line, and the sidebar's change list dots each entry — and they
/// are the same claim about the same repository, so they are the same colours.
/// Before this they were three separate literals and the tree agreed with neither
/// of the others.
///
/// The values are the ones VS Code settled on rather than the system's `.green`
/// and `.red`, which are tuned for buttons: they are muted enough to sit under a
/// file name for a whole session without shouting, and light enough to carry a
/// three-point stripe on a dark gutter. Fixed rather than theme-derived, for the
/// same reason the syntax themes are checked in — a changed file should look the
/// same on every Mac.
enum GitChangeColors {
    static let added = Color(nsColor: addedNS)
    static let renamed = Color(nsColor: renamedNS)
    static let modified = Color(nsColor: modifiedNS)
    static let deleted = Color(nsColor: deletedNS)
    static let conflicted = Color(nsColor: conflictedNS)

    /// The gutter is AppKit and draws into a `CGContext`, so it wants these
    /// rather than the SwiftUI wrappers above.
    static let addedNS = NSColor(rgb: 0x73_C9_91)
    static let renamedNS = NSColor(rgb: 0x6C_9E_F8)
    static let modifiedNS = NSColor(rgb: 0xE2_C0_8D)
    static let deletedNS = NSColor(rgb: 0xC7_4E_39)
    static let conflictedNS = NSColor(rgb: 0xE4_67_6B)

    static func color(for kind: GitChangeKind) -> Color {
        switch kind {
        case .added: added
        case .renamed: renamed
        case .modified: modified
        case .deleted: deleted
        case .conflicted: conflicted
        }
    }
}

extension GitChangeKind {
    var color: Color { GitChangeColors.color(for: self) }
}
