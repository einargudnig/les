import Cocoa

final class KeyboardHelpPanel {
    private static var panel: NSPanel?

    static func toggle(relativeTo window: NSWindow) {
        if let existing = panel, existing.isVisible {
            existing.orderOut(nil)
            panel = nil
            return
        }

        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 460),
            styleMask: [.titled, .closable, .nonactivatingPanel, .hudWindow],
            backing: .buffered,
            defer: false
        )
        p.title = "Keyboard Shortcuts"
        p.isFloatingPanel = true
        p.becomesKeyOnlyIfNeeded = true
        p.isMovableByWindowBackground = true
        p.contentView = buildContent()

        // Center on parent window
        let parentFrame = window.frame
        let panelSize = p.frame.size
        let x = parentFrame.midX - panelSize.width / 2
        let y = parentFrame.midY - panelSize.height / 2
        p.setFrameOrigin(NSPoint(x: x, y: y))

        p.orderFront(nil)
        panel = p
    }

    private static func buildContent() -> NSView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false

        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false

        let sections: [(String, [(String, String)])] = [
            ("Navigation", [
                ("j / k", "Next / previous item"),
                ("j / k", "Scroll down / up (in reader)"),
                ("h / l", "Move focus left / right"),
                ("o", "Focus reader pane"),
                ("gg", "Go to top"),
                ("G", "Go to bottom"),
                ("n / p", "Next / previous unread"),
                ("/", "Focus search"),
                ("Esc", "Back to items list"),
            ]),
            ("Actions", [
                ("m", "Toggle read / unread"),
                ("s", "Toggle star"),
                ("O", "Open in browser"),
                ("b", "Add bookmark"),
                ("r", "Refresh current feed"),
                ("R", "Refresh all feeds"),
            ]),
            ("App", [
                ("⌘N", "Add feed"),
                ("⌘B", "Add bookmark"),
                ("⌘R", "Refresh feed"),
                ("⇧⌘R", "Refresh all"),
                ("⌘Q", "Quit"),
                ("?", "Toggle this help"),
            ]),
        ]

        var views: [NSView] = []
        var y: CGFloat = 16

        for (sectionTitle, shortcuts) in sections.reversed() {
            // Shortcuts (bottom up since we flip later)
            for (key, desc) in shortcuts.reversed() {
                let row = makeRow(key: key, description: desc)
                row.frame.origin = NSPoint(x: 0, y: y)
                views.append(row)
                y += 28
            }

            // Section header
            let header = NSTextField(labelWithString: sectionTitle.uppercased())
            header.font = .systemFont(ofSize: 10, weight: .semibold)
            header.textColor = .tertiaryLabelColor
            header.frame = NSRect(x: 24, y: y + 4, width: 380, height: 16)
            views.append(header)
            y += 32
        }

        content.frame = NSRect(x: 0, y: 0, width: 420, height: y + 8)

        for v in views {
            content.addSubview(v)
        }

        scroll.documentView = content
        return scroll
    }

    private static func makeRow(key: String, description: String) -> NSView {
        let row = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 26))

        let keyLabel = NSTextField(labelWithString: key)
        keyLabel.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        keyLabel.textColor = .labelColor
        keyLabel.alignment = .right
        keyLabel.frame = NSRect(x: 24, y: 3, width: 80, height: 20)

        let descLabel = NSTextField(labelWithString: description)
        descLabel.font = .systemFont(ofSize: 12, weight: .regular)
        descLabel.textColor = .secondaryLabelColor
        descLabel.frame = NSRect(x: 120, y: 3, width: 280, height: 20)

        row.addSubview(keyLabel)
        row.addSubview(descLabel)
        return row
    }
}
