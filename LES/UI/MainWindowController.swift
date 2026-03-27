import Cocoa

class MainWindowController: NSWindowController {
    var feedsVC: FeedsViewController!
    var itemsVC: ItemsViewController!
    var readerVC: ReaderViewController!

    convenience init() {
        let window = KeyWindow(
            contentRect: NSRect(x: 196, y: 240, width: 1200, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "LES"
        window.minSize = NSSize(width: 800, height: 400)
        window.setFrameAutosaveName("MainWindow")
        window.titlebarAppearsTransparent = false
        window.titleVisibility = .visible
        window.toolbarStyle = .unified

        self.init(window: window)
        setupSplitView()
    }

    private func setupSplitView() {
        feedsVC = FeedsViewController()
        itemsVC = ItemsViewController()
        readerVC = ReaderViewController()

        let splitVC = NSSplitViewController()

        let feedsItem = NSSplitViewItem(sidebarWithViewController: feedsVC)
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

        feedsVC.onFeedSelected = { [weak self] feedId in
            self?.itemsVC.showItems(forFeedId: feedId)
            self?.readerVC.clear()
        }

        itemsVC.onItemSelected = { [weak self] itemId in
            self?.readerVC.showItem(itemId: itemId)
        }
    }

    // MARK: - Actions (responder chain)

    @objc func refreshCurrentFeed(_ sender: Any?) {
        guard let feedId = feedsVC?.selectedFeedId else { return }
        Task {
            await RefreshScheduler.shared.refreshFeed(id: feedId)
            await MainActor.run {
                self.feedsVC?.reloadFeeds()
                self.itemsVC?.reload()
            }
        }
    }

    @objc func refreshAllFeeds(_ sender: Any?) {
        Task {
            await RefreshScheduler.shared.refreshAllFeeds()
            await MainActor.run {
                self.feedsVC?.reloadFeeds()
                self.itemsVC?.reload()
            }
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
                        self?.feedsVC?.reloadFeeds()
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
                        self?.feedsVC?.reloadFeeds()
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
        window?.makeFirstResponder(feedsVC?.outlineView)
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
}
