import Cocoa

/// NSWindow subclass that intercepts key events for vim-like navigation
class KeyWindow: NSWindow {
    private var pendingKey: Character?
    private var pendingTimer: Timer?
    private let sequenceTimeout: TimeInterval = 0.7

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, handleVimKey(event) {
            return // consumed
        }
        super.sendEvent(event)
    }

    private func handleVimKey(_ event: NSEvent) -> Bool {
        // Don't intercept keys when a text input is first responder
        if isEditingText { return false }

        guard let chars = event.charactersIgnoringModifiers, let char = chars.first else {
            return false
        }

        // Check for modifier keys — pass through Cmd/Ctrl combos
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) || flags.contains(.control) {
            return false
        }

        // Multi-key sequence handling
        if let pending = pendingKey {
            pendingTimer?.invalidate()
            pendingTimer = nil
            pendingKey = nil

            if pending == "g" && char == "g" {
                performAction(.goToTop)
                return true
            }
            // Unknown sequence, ignore
            return false
        }

        // Single-key commands — j/k are context-sensitive
        switch char {
        case "j":
            if isReaderFocused {
                performAction(.scrollDown)
            } else {
                performAction(.nextItem)
            }
            return true
        case "k":
            if isReaderFocused {
                performAction(.scrollUp)
            } else {
                performAction(.previousItem)
            }
            return true
        case "h":
            performAction(.focusLeft)
            return true
        case "l":
            performAction(.focusRight)
            return true
        case "G":
            performAction(.goToBottom)
            return true
        case "g":
            // Start multi-key sequence
            pendingKey = "g"
            pendingTimer = Timer.scheduledTimer(withTimeInterval: sequenceTimeout, repeats: false) { [weak self] _ in
                self?.pendingKey = nil
            }
            return true
        case "n":
            performAction(.nextUnread)
            return true
        case "p":
            performAction(.previousUnread)
            return true
        case "m":
            performAction(.toggleRead)
            return true
        case "s":
            performAction(.toggleStar)
            return true
        case "o":
            performAction(.focusReader)
            return true
        case "O":
            performAction(.openInBrowser)
            return true
        case "/":
            performAction(.focusSearch)
            return true
        case "r":
            performAction(.refreshCurrentFeed)
            return true
        case "R":
            performAction(.refreshAllFeeds)
            return true
        case "b":
            performAction(.addBookmark)
            return true
        default:
            break
        }

        // Escape clears search / returns focus
        if event.keyCode == 53 { // Escape
            performAction(.escape)
            return true
        }

        return false
    }

    private var isEditingText: Bool {
        guard let responder = firstResponder else { return false }
        if let textView = responder as? NSTextView {
            return textView.isEditable
        }
        if responder is NSTextField {
            return true
        }
        return false
    }

    private var isReaderFocused: Bool {
        guard let wc = windowController as? MainWindowController,
              let readerTextView = wc.readerVC?.textView else { return false }
        return firstResponder === readerTextView
    }

    private func performAction(_ action: VimAction) {
        guard let wc = windowController as? MainWindowController else { return }

        switch action {
        case .nextItem:
            wc.itemsVC?.selectNextItem()
        case .previousItem:
            wc.itemsVC?.selectPreviousItem()
        case .goToTop:
            wc.itemsVC?.selectFirstItem()
        case .goToBottom:
            wc.itemsVC?.selectLastItem()
        case .nextUnread:
            wc.itemsVC?.selectNextUnread()
        case .previousUnread:
            wc.itemsVC?.selectPreviousUnread()
        case .toggleRead:
            wc.itemsVC?.toggleReadCurrent()
        case .toggleStar:
            wc.itemsVC?.toggleStarCurrent()
        case .openInBrowser:
            wc.itemsVC?.openCurrentInBrowser()
        case .focusLeft:
            focusLeftPane(wc)
        case .focusRight:
            focusRightPane(wc)
        case .focusReader:
            wc.focusReaderPane()
        case .focusSearch:
            wc.focusSearch()
        case .refreshCurrentFeed:
            wc.refreshCurrentFeed(nil)
        case .refreshAllFeeds:
            wc.refreshAllFeeds(nil)
        case .addBookmark:
            wc.addBookmark(nil)
        case .scrollDown:
            wc.readerVC?.scrollDown()
        case .scrollUp:
            wc.readerVC?.scrollUp()
        case .escape:
            // Return focus to items list
            wc.focusItemsPane()
        }
    }

    private func focusLeftPane(_ wc: MainWindowController) {
        // Cycle: reader -> items -> feeds
        if firstResponder is NSTextView {
            // Likely reader, go to items
            wc.focusItemsPane()
        } else {
            wc.focusFeedsPane()
        }
    }

    private func focusRightPane(_ wc: MainWindowController) {
        // Cycle: feeds -> items -> reader
        if let fr = firstResponder, fr is NSOutlineView {
            wc.focusItemsPane()
        } else {
            wc.focusReaderPane()
        }
    }

}

private enum VimAction {
    case nextItem, previousItem
    case goToTop, goToBottom
    case nextUnread, previousUnread
    case toggleRead, toggleStar
    case openInBrowser
    case focusLeft, focusRight, focusReader
    case focusSearch
    case refreshCurrentFeed, refreshAllFeeds
    case scrollDown, scrollUp
    case addBookmark
    case escape
}
