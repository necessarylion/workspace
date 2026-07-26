import AppKit
import SwiftUI

/// SwiftUI wrapper around ``CodeEditorController``.
///
/// The controller is the source of truth while editing; the document is updated
/// from it, never the other way round — except when the file is reloaded from
/// disk, which bumps `externalRevision`.
struct CodeEditorView: NSViewControllerRepresentable {
    let document: OpenDocument
    let projectRoot: URL?
    var wrapsLines: Bool
    /// The font and colours from Settings, passed in rather than read here: a
    /// representable is not a view body, so nothing it reads is observed.
    var theme: SyntaxTheme
    /// False when the file was opened from the file tree, which keeps the
    /// keyboard for its own shortcuts until the text is clicked.
    var takesFocusOnAppear = true
    /// What the file search is looking for, marked wherever it occurs here.
    var searchHighlight: String?
    var onOpenLocation: ((URL, Int) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSViewController(context: Context) -> CodeEditorController {
        let controller = CodeEditorController()
        let coordinator = context.coordinator
        coordinator.controller = controller
        // Read once, here: the only thing it decides is `viewDidAppear`, which
        // happens moments after this and never again for this controller.
        controller.takesFocusOnAppear = takesFocusOnAppear
        // Before the view loads, so the file is laid out in the right font once.
        controller.applyAppearance(theme)

        // Every callback goes through the coordinator: the controller is
        // reused across files, and closures capturing `document` directly
        // would keep feeding the first file ever opened.
        controller.onTextChange = { text in
            coordinator.document?.applyEditorText(text)
        }
        controller.onCaretChange = { line, column in
            coordinator.document?.caretLine = line
            coordinator.document?.caretColumn = column
        }
        controller.onDiagnostics = { diagnostics in
            coordinator.document?.diagnostics = diagnostics
        }
        controller.onSymbols = { symbols in
            coordinator.document?.symbols = symbols
        }
        controller.onStatusChange = { status in
            coordinator.document?.languageServerStatus = status
        }
        controller.onOpenLocation = { url, line in
            coordinator.onOpenLocation?(url, line)
        }
        return controller
    }

    func updateNSViewController(_ controller: CodeEditorController, context: Context) {
        let coordinator = context.coordinator
        coordinator.document = document
        coordinator.onOpenLocation = onOpenLocation

        if controller.fileURL != document.url {
            controller.load(url: document.url, text: document.text, projectRoot: projectRoot)
            coordinator.revision = document.externalRevision
            coordinator.saveRevision = document.saveRevision
        } else if coordinator.revision != document.externalRevision {
            coordinator.revision = document.externalRevision
            controller.replaceText(document.text)
        }

        if coordinator.saveRevision != document.saveRevision {
            coordinator.saveRevision = document.saveRevision
            controller.documentSaved()
        }

        if controller.wrapsLines != wrapsLines {
            controller.wrapsLines = wrapsLines
        }

        controller.applyAppearance(theme)

        // After `load`, so a file opened from a search result is marked once its
        // text is there rather than while the controller still holds the last.
        controller.searchHighlight = searchHighlight

        if let line = document.revealLine {
            // Clearing the request is a state change, so it waits a runloop turn.
            Task { @MainActor in
                document.revealLine = nil
                controller.reveal(line: line)
            }
        }
    }

    @MainActor
    final class Coordinator {
        var controller: CodeEditorController?
        var document: OpenDocument?
        var onOpenLocation: ((URL, Int) -> Void)?
        var revision = 0
        var saveRevision = 0
    }
}
