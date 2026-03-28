import Cocoa

class MainWindowController: NSWindowController {
    var sidebarVC: SidebarViewController!
    var itemsVC: ItemsViewController!
    var readerVC: ReaderViewController!

    convenience init() {
        let window = KeyWindow(
            contentRect: NSRect(x: 196, y: 240, width: 1200, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "les"
        window.minSize = NSSize(width: 800, height: 400)
        window.setFrameAutosaveName("MainWindow")
        window.titlebarAppearsTransparent = false
        window.titleVisibility = .visible
        window.toolbarStyle = .unified

        self.init(window: window)
        setupSplitView()
        setupToolbar()
    }

    private func setupSplitView() {
        sidebarVC = SidebarViewController()
        itemsVC = ItemsViewController()
        readerVC = ReaderViewController()

        let splitVC = NSSplitViewController()

        let feedsItem = NSSplitViewItem(sidebarWithViewController: sidebarVC)
        feedsItem.minimumThickness = 180
        feedsItem.maximumThickness = 300
        feedsItem.canCollapse = true

        let itemsItem = NSSplitViewItem(contentListWithViewController: itemsVC)
        itemsItem.minimumThickness = 250
        itemsItem.canCollapse = false

        let readerItem = NSSplitViewItem(viewController: readerVC)
        readerItem.minimumThickness = 300
        readerItem.canCollapse = true

        splitVC.addSplitViewItem(feedsItem)
        splitVC.addSplitViewItem(itemsItem)
        splitVC.addSplitViewItem(readerItem)

        window?.contentViewController = splitVC

        sidebarVC.onSelectionChanged = { [weak self] selection in
            switch selection {
            case .smartView(let sv):
                self?.itemsVC.showItems(forFilter: sv.filter)
            case .feed(let feedId):
                self?.itemsVC.showItems(forFeedId: feedId)
            }
            self?.readerVC.clear()
        }

        itemsVC.onItemSelected = { [weak self] itemId in
            self?.readerVC.showItem(itemId: itemId)
        }

        itemsVC.onReadStateChanged = { [weak self] in
            self?.sidebarVC?.refreshCounts()
        }

        sidebarVC.onDeleteFeed = { [weak self] feedId in
            try? FeedStore(db: DatabaseManager.shared.dbPool).deleteFeed(id: feedId)
            self?.sidebarVC?.reloadData()
            self?.itemsVC?.reload()
            self?.readerVC?.clear()
        }

        sidebarVC.onMarkAllRead = { [weak self] feedId in
            try? ItemStore(db: DatabaseManager.shared.dbPool).markAllRead(feedId: feedId)
            self?.sidebarVC?.reloadData()
            self?.itemsVC?.reload()
        }

        sidebarVC.onMarkAllReadGlobal = { [weak self] in
            try? ItemStore(db: DatabaseManager.shared.dbPool).markAllRead()
            self?.sidebarVC?.reloadData()
            self?.itemsVC?.reload()
        }
    }

    // MARK: - Actions (responder chain)

    @objc func refreshCurrentFeed(_ sender: Any?) {
        guard let feedId = sidebarVC?.selectedFeedId else { return }
        Task {
            await RefreshScheduler.shared.refreshFeed(id: feedId)
            await MainActor.run {
                self.sidebarVC?.reloadData()
                self.itemsVC?.reload()
            }
        }
    }

    @objc func refreshAllFeeds(_ sender: Any?) {
        showRefreshSpinner(true)
        Task {
            await RefreshScheduler.shared.refreshAllFeeds()
            await MainActor.run {
                self.showRefreshSpinner(false)
                self.sidebarVC?.reloadData()
                self.itemsVC?.reload()
            }
        }
    }

    private func showRefreshSpinner(_ show: Bool) {
        guard let toolbar = window?.toolbar,
              let item = toolbar.items.first(where: { $0.itemIdentifier == .refreshAll }) else { return }
        if show {
            let spinner = NSProgressIndicator()
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.frame = NSRect(x: 0, y: 0, width: 18, height: 18)
            spinner.startAnimation(nil)
            item.view = spinner
        } else {
            item.view = nil
            item.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh")
        }
    }

    @objc func addFeed(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Add Feed"
        alert.informativeText = "Enter the RSS/Atom feed URL:"
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 400, height: 24))
        input.placeholderString = "https://example.com/feed.xml"
        alert.accessoryView = input

        guard let window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            let urlString = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !urlString.isEmpty else { return }

            Task {
                do {
                    let feedStore = FeedStore(db: DatabaseManager.shared.dbPool)
                    let feed = try feedStore.insertFeed(url: urlString)
                    if let feedId = feed.id {
                        await RefreshScheduler.shared.refreshFeed(id: feedId)
                    }
                    await MainActor.run {
                        self?.sidebarVC?.reloadData()
                    }
                } catch {
                    await MainActor.run {
                        let errAlert = NSAlert(error: error)
                        errAlert.runModal()
                    }
                }
            }
        }
    }

    @objc func addBookmark(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Add Bookmark"
        alert.informativeText = "Enter the URL to bookmark:"
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 400, height: 24))
        input.placeholderString = "https://example.com/article"
        alert.accessoryView = input

        guard let window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            let urlString = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !urlString.isEmpty else { return }

            Task {
                do {
                    try await BookmarkService().addBookmark(url: urlString, db: DatabaseManager.shared.dbPool)
                    await MainActor.run {
                        self?.sidebarVC?.reloadData()
                        self?.itemsVC?.reload()
                    }
                } catch {
                    await MainActor.run {
                        let errAlert = NSAlert(error: error)
                        errAlert.runModal()
                    }
                }
            }
        }
    }

    @objc func importOPML(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.xml]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        guard let window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task {
                do {
                    let data = try Data(contentsOf: url)
                    let feeds = OPMLParser.parse(data: data)
                    let feedStore = FeedStore(db: DatabaseManager.shared.dbPool)
                    for opmlFeed in feeds {
                        try? feedStore.insertFeed(url: opmlFeed.url, title: opmlFeed.title, folder: opmlFeed.folder)
                    }
                    await RefreshScheduler.shared.refreshAllFeeds()
                    await MainActor.run {
                        self?.sidebarVC?.reloadData()
                    }
                } catch {
                    await MainActor.run {
                        let errAlert = NSAlert(error: error)
                        errAlert.runModal()
                    }
                }
            }
        }
    }

    // MARK: - Focus management for vim nav

    func focusFeedsPane() {
        window?.makeFirstResponder(sidebarVC?.outlineView)
    }

    func focusItemsPane() {
        window?.makeFirstResponder(itemsVC?.tableView)
    }

    func focusReaderPane() {
        window?.makeFirstResponder(readerVC?.textView)
    }

    func focusSearch() {
        itemsVC?.focusSearch()
    }

    // MARK: - Toolbar

    private func setupToolbar() {
        let toolbar = NSToolbar(identifier: "MainToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window?.toolbar = toolbar
    }
}

// MARK: - NSToolbarDelegate

private extension NSToolbarItem.Identifier {
    static let refreshAll = NSToolbarItem.Identifier("refreshAll")
    static let addFeed = NSToolbarItem.Identifier("addFeed")
    static let addBookmark = NSToolbarItem.Identifier("addBookmark")
}

extension MainWindowController: NSToolbarDelegate {
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier {
        case .refreshAll:
            let item = NSToolbarItem(itemIdentifier: .refreshAll)
            item.label = "Refresh"
            item.toolTip = "Refresh all feeds"
            item.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh")
            item.target = self
            item.action = #selector(refreshAllFeeds(_:))
            return item

        case .addFeed:
            let item = NSToolbarItem(itemIdentifier: .addFeed)
            item.label = "Add Feed"
            item.toolTip = "Add RSS feed"
            item.image = NSImage(systemSymbolName: "plus.circle", accessibilityDescription: "Add Feed")
            item.target = self
            item.action = #selector(addFeed(_:))
            return item

        case .addBookmark:
            let item = NSToolbarItem(itemIdentifier: .addBookmark)
            item.label = "Bookmark"
            item.toolTip = "Add bookmark"
            item.image = NSImage(systemSymbolName: "bookmark.fill", accessibilityDescription: "Add Bookmark")
            item.target = self
            item.action = #selector(addBookmark(_:))
            return item

        default:
            return nil
        }
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.addFeed, .addBookmark, .flexibleSpace, .refreshAll]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.addFeed, .addBookmark, .flexibleSpace, .refreshAll]
    }
}
