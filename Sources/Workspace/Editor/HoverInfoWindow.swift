import AppKit

/// A small floating panel used for hover help and diagnostic messages.
///
/// A child window rather than an `NSPopover`: it must never take focus away
/// from the text view, and it needs to appear and vanish as the mouse moves.
@MainActor
final class HoverInfoWindow {
    private let panel: NSPanel
    private let label = NSTextField(labelWithString: "")
    private let iconView = NSImageView()

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 60),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovable = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu

        let background = NSVisualEffectView()
        background.material = .toolTip
        background.blendingMode = .withinWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 7
        background.layer?.borderWidth = 1
        background.layer?.borderColor = NSColor.separatorColor.cgColor

        iconView.imageScaling = .scaleProportionallyDown

        label.font = .systemFont(ofSize: 11.5)
        label.textColor = .labelColor
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 14
        label.preferredMaxLayoutWidth = 380

        let stack = NSStackView(views: [iconView, label])
        stack.orientation = .horizontal
        stack.alignment = .top
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 7, left: 8, bottom: 7, right: 9)
        stack.translatesAutoresizingMaskIntoConstraints = false

        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            stack.topAnchor.constraint(equalTo: background.topAnchor),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor)
        ])

        panel.contentView = background
    }

    var isVisible: Bool { panel.isVisible }

    /// Shows `text` just below `rect` (given in `view`'s coordinates).
    func show(text: String, symbol: String?, tint: NSColor, below rect: NSRect, in view: NSView) {
        guard let window = view.window else { return }

        label.stringValue = text
        label.textColor = .labelColor
        if let symbol {
            iconView.image = NSImage(
                systemSymbolName: symbol,
                accessibilityDescription: nil
            )
            iconView.contentTintColor = tint
            iconView.isHidden = false
        } else {
            iconView.image = nil
            iconView.isHidden = true
        }

        let maxWidth: CGFloat = 460
        label.preferredMaxLayoutWidth = maxWidth - 40
        let fitting = panel.contentView?.fittingSize ?? CGSize(width: 260, height: 44)
        let size = CGSize(width: min(max(fitting.width, 140), maxWidth), height: fitting.height)

        let inView = view.convert(rect, to: nil)
        let onScreen = window.convertToScreen(inView)
        var origin = NSPoint(x: onScreen.minX, y: onScreen.minY - size.height - 6)

        if let screen = window.screen {
            origin.x = min(origin.x, screen.visibleFrame.maxX - size.width - 8)
            origin.x = max(origin.x, screen.visibleFrame.minX + 8)
            // Flip above the line when there is no room below.
            if origin.y < screen.visibleFrame.minY + 8 {
                origin.y = onScreen.maxY + 6
            }
        }

        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        if !panel.isVisible {
            window.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)
    }

    func hide() {
        guard panel.isVisible else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }
}
