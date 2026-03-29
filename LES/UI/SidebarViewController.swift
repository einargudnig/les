import Cocoa

// MARK: - Sidebar types

enum SidebarSelection {
    case smartView(SmartView)
    case feed(Int64)
}

enum SmartView: String, CaseIterable {
    case inbox = "Inbox"
    case readingList = "Reading List"
    case starred = "Starred"
    case today = "Today"

    var symbolName: String {
        switch self {
        case .inbox: return "tray"
        case .readingList: return "book"
        case .starred: return "star"
        case .today: return "calendar"
        }
    }

    var filter: ItemFilter {
        switch self {
        case .inbox: return .unread
        case .readingList: return .readingList
        case .starred: return .starred
        case .today: return .today
        }
    }
}

// MARK: - Wrapper classes (NSOutlineView needs reference types)

private class SmartViewItem: NSObject {
    let smartView: SmartView
    var count: Int = 0

    init(_ smartView: SmartView) {
        self.smartView = smartView
    }
}

private class DividerItem: NSObject {}

private class FolderItem: NSObject {
    let name: String
    var feeds: [FeedItem] = []

    init(name: String) {
        self.name = name
    }
}

private class FeedItem: NSObject {
    var viewModel: FeedRecord.RowViewModel

    init(_ viewModel: FeedRecord.RowViewModel) {
        self.viewModel = viewModel
    }
}

// MARK: - SidebarViewController

class SidebarViewController: NSViewController {
    var onSelectionChanged: ((SidebarSelection) -> Void)?
    var onDeleteFeed: ((Int64) -> Void)?
    var onMarkAllRead: ((Int64) -> Void)?
    var onMarkAllReadGlobal: (() -> Void)?
    private(set) var outlineView: NSOutlineView!
    private var scrollView: NSScrollView!

    private let accentColor = Theme.accent

    // Data
    private var smartViewItems: [SmartViewItem] = SmartView.allCases.map { SmartViewItem($0) }
    private let dividerItem = DividerItem()
    private var feedRootItems: [AnyObject] = [] // FolderItem or FeedItem

    var selectedFeedId: Int64? {
        let row = outlineView.selectedRow
        guard row >= 0 else { return nil }
        if let feedItem = outlineView.item(atRow: row) as? FeedItem {
            return feedItem.viewModel.id
        }
        return nil
    }

    var currentSelection: SidebarSelection? {
        let row = outlineView.selectedRow
        guard row >= 0 else { return nil }
        if let svItem = outlineView.item(atRow: row) as? SmartViewItem {
            return .smartView(svItem.smartView)
        }
        if let feedItem = outlineView.item(atRow: row) as? FeedItem {
            return .feed(feedItem.viewModel.id)
        }
        return nil
    }

    override func loadView() {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay

        outlineView = NSOutlineView()
        outlineView.headerView = nil
        outlineView.rowHeight = Theme.sidebarRowHeight
        outlineView.indentationPerLevel = Theme.spacingMD + 2
        outlineView.style = .sourceList

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("SidebarColumn"))
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column

        outlineView.delegate = self
        outlineView.dataSource = self

        // Context menu
        let menu = NSMenu()
        menu.delegate = self
        outlineView.menu = menu

        scrollView.documentView = outlineView
        container.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])

        self.view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        reloadData()
    }

    /// Full reload — updates counts and rebuilds feed list
    func reloadData() {
        updateCounts()

        // Load feeds
        do {
            let feedStore = FeedStore(db: DatabaseManager.shared.dbPool)
            let feeds = try feedStore.listFeeds()
            buildFeedItems(from: feeds)
        } catch {}

        outlineView.reloadData()

        // Expand all folders
        for item in feedRootItems {
            if item is FolderItem {
                outlineView.expandItem(item)
            }
        }
    }

    private func updateCounts() {
        do {
            let store = ItemStore(db: DatabaseManager.shared.dbPool)
            for svItem in smartViewItems {
                switch svItem.smartView {
                case .inbox:
                    svItem.count = try store.inboxUnreadCount()
                case .readingList:
                    svItem.count = try store.readingListUnreadCount()
                case .starred:
                    svItem.count = try store.starredCount()
                case .today:
                    svItem.count = try store.todayUnreadCount()
                }
            }
        } catch {}
    }

    /// Lightweight refresh — updates counts and redraws visible rows without rebuilding the tree
    func refreshCounts() {
        updateCounts()

        // Also refresh feed unread counts
        do {
            let feedStore = FeedStore(db: DatabaseManager.shared.dbPool)
            let feeds = try feedStore.listFeeds()
            let feedMap = Dictionary(uniqueKeysWithValues: feeds.map { ($0.id, $0) })

            // Update existing feed items in place
            func updateFeeds(in items: [AnyObject]) {
                for item in items {
                    if let feedItem = item as? FeedItem,
                       let updated = feedMap[feedItem.viewModel.id] {
                        feedItem.viewModel = updated
                    }
                    if let folder = item as? FolderItem {
                        for fi in folder.feeds {
                            if let updated = feedMap[fi.viewModel.id] {
                                fi.viewModel = updated
                            }
                        }
                    }
                }
            }
            updateFeeds(in: feedRootItems)
        } catch {}

        // Redraw visible rows without reloading tree structure
        let visibleRows = outlineView.rows(in: outlineView.visibleRect)
        outlineView.reloadData(forRowIndexes: IndexSet(integersIn: visibleRows.lowerBound..<visibleRows.upperBound),
                               columnIndexes: IndexSet(integer: 0))
    }

    private func buildFeedItems(from feeds: [FeedRecord.RowViewModel]) {
        var grouped: [String: [FeedRecord.RowViewModel]] = [:]
        var noFolder: [FeedRecord.RowViewModel] = []

        for feed in feeds {
            if let folder = feed.folder {
                grouped[folder, default: []].append(feed)
            } else {
                noFolder.append(feed)
            }
        }

        feedRootItems = []

        // If all feeds are in one flat group, just list them directly
        if grouped.isEmpty {
            feedRootItems = noFolder.map { FeedItem($0) }
            return
        }

        // Otherwise, use folders
        if !noFolder.isEmpty {
            let folder = FolderItem(name: "Feeds")
            folder.feeds = noFolder.map { FeedItem($0) }
            feedRootItems.append(folder)
        }
        for folderName in grouped.keys.sorted() {
            let folder = FolderItem(name: folderName)
            folder.feeds = grouped[folderName]!.map { FeedItem($0) }
            feedRootItems.append(folder)
        }
    }

    // All root-level items in order
    private var rootItems: [AnyObject] {
        var items: [AnyObject] = []
        items.append(contentsOf: smartViewItems)
        items.append(dividerItem)
        items.append(contentsOf: feedRootItems)
        return items
    }

    // MARK: - Vim navigation

    func selectNext() {
        let row = outlineView.selectedRow
        var nextRow = row + 1
        while nextRow < outlineView.numberOfRows {
            if outlineView.item(atRow: nextRow) is DividerItem || outlineView.item(atRow: nextRow) is FolderItem {
                nextRow += 1
                continue
            }
            outlineView.selectRowIndexes(IndexSet(integer: nextRow), byExtendingSelection: false)
            outlineView.scrollRowToVisible(nextRow)
            notifySelection()
            return
        }
    }

    func selectPrevious() {
        let row = outlineView.selectedRow
        var prevRow = row - 1
        while prevRow >= 0 {
            if outlineView.item(atRow: prevRow) is DividerItem || outlineView.item(atRow: prevRow) is FolderItem {
                prevRow -= 1
                continue
            }
            outlineView.selectRowIndexes(IndexSet(integer: prevRow), byExtendingSelection: false)
            outlineView.scrollRowToVisible(prevRow)
            notifySelection()
            return
        }
    }

    private func notifySelection() {
        guard let sel = currentSelection else { return }
        onSelectionChanged?(sel)
    }
}

// MARK: - NSOutlineViewDataSource

extension SidebarViewController: NSOutlineViewDataSource {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil {
            return smartViewItems.count + 1 + feedRootItems.count
        }
        if let folder = item as? FolderItem {
            return folder.feeds.count
        }
        return 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil {
            let all = rootItems
            return all[index]
        }
        if let folder = item as? FolderItem {
            return folder.feeds[index]
        }
        return NSObject()
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        return item is FolderItem
    }
}

// MARK: - NSOutlineViewDelegate

extension SidebarViewController: NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        if item is DividerItem { return 25 }
        return 28
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        if item is DividerItem { return false }
        if item is FolderItem { return false }
        return true
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if item is DividerItem {
            return makeDividerCell()
        }

        if let svItem = item as? SmartViewItem {
            let cellID = NSUserInterfaceItemIdentifier("SmartViewCell")
            let cell = outlineView.makeView(withIdentifier: cellID, owner: self) as? SmartViewCellView
                ?? SmartViewCellView(identifier: cellID, accentColor: accentColor)
            cell.configure(symbolName: svItem.smartView.symbolName, title: svItem.smartView.rawValue, count: svItem.count)
            return cell
        }

        if let folder = item as? FolderItem {
            let cellID = NSUserInterfaceItemIdentifier("FolderCell")
            let cell = outlineView.makeView(withIdentifier: cellID, owner: self) as? NSTableCellView
                ?? makeFolderCell(identifier: cellID)
            cell.textField?.stringValue = folder.name.uppercased()
            return cell
        }

        if let feedItem = item as? FeedItem {
            let cellID = NSUserInterfaceItemIdentifier("FeedCell")
            let cell = outlineView.makeView(withIdentifier: cellID, owner: self) as? FeedCellView
                ?? FeedCellView(identifier: cellID, accentColor: accentColor)
            cell.configure(title: feedItem.viewModel.title, unreadCount: feedItem.viewModel.unreadCount, isMuted: feedItem.viewModel.isMuted, hasError: feedItem.viewModel.hasError, siteHost: feedItem.viewModel.siteHost)
            return cell
        }

        return nil
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        notifySelection()
    }

    // MARK: - Cell factories

    private func makeDividerCell() -> NSView {
        let cell = NSTableCellView()
        let line = NSView()
        line.translatesAutoresizingMaskIntoConstraints = false
        line.wantsLayer = true
        line.layer?.backgroundColor = NSColor.separatorColor.cgColor
        cell.addSubview(line)
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: Theme.spacingMD),
            line.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -Theme.spacingMD),
            line.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            line.heightAnchor.constraint(equalToConstant: 1),
        ])
        return cell
    }

    private func makeFolderCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let tf = NSTextField(labelWithString: "")
        tf.translatesAutoresizingMaskIntoConstraints = false
        tf.font = Theme.sidebarSectionFont
        tf.textColor = .tertiaryLabelColor
        tf.lineBreakMode = .byTruncatingTail
        cell.addSubview(tf)
        cell.textField = tf
        NSLayoutConstraint.activate([
            tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: Theme.spacingSM),
            tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -Theme.spacingSM),
            tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}

// MARK: - SmartViewCellView

private class SmartViewCellView: NSTableCellView {
    private let iconView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let countBadge = NSTextField(labelWithString: "")

    convenience init(identifier: NSUserInterfaceItemIdentifier, accentColor: NSColor) {
        self.init()
        self.identifier = identifier

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.contentTintColor = .secondaryLabelColor
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        addSubview(iconView)

        titleField.translatesAutoresizingMaskIntoConstraints = false
        titleField.lineBreakMode = .byTruncatingTail
        addSubview(titleField)

        countBadge.translatesAutoresizingMaskIntoConstraints = false
        countBadge.alignment = .center
        countBadge.wantsLayer = true
        countBadge.layer?.cornerRadius = 6
        countBadge.isBezeled = false
        countBadge.drawsBackground = false
        countBadge.textColor = accentColor
        addSubview(countBadge)

        self.textField = titleField
        self.imageView = iconView

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.spacingSM),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 18),
            iconView.heightAnchor.constraint(equalToConstant: 18),

            titleField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: Theme.spacingSM),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleField.trailingAnchor.constraint(lessThanOrEqualTo: countBadge.leadingAnchor, constant: -Theme.spacingSM),

            countBadge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.spacingMD),
            countBadge.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    func configure(symbolName: String, title: String, count: Int) {
        iconView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: title)
        titleField.stringValue = title
        titleField.font = .systemFont(ofSize: 13, weight: count > 0 ? .medium : .regular)
        titleField.textColor = .labelColor

        if count > 0 {
            countBadge.stringValue = "\(count)"
            countBadge.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            countBadge.isHidden = false
        } else {
            countBadge.isHidden = true
        }
    }
}

// MARK: - FeedCellView (same as old FeedsViewController)

private class FeedCellView: NSTableCellView {
    private let faviconView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let countBadge = NSTextField(labelWithString: "")

    convenience init(identifier: NSUserInterfaceItemIdentifier, accentColor: NSColor) {
        self.init()
        self.identifier = identifier

        faviconView.translatesAutoresizingMaskIntoConstraints = false
        faviconView.wantsLayer = true
        faviconView.layer?.cornerRadius = Theme.radiusSM
        faviconView.layer?.masksToBounds = true
        faviconView.imageScaling = .scaleProportionallyDown
        addSubview(faviconView)

        titleField.translatesAutoresizingMaskIntoConstraints = false
        titleField.lineBreakMode = .byTruncatingTail
        addSubview(titleField)

        countBadge.translatesAutoresizingMaskIntoConstraints = false
        countBadge.alignment = .center
        countBadge.wantsLayer = true
        countBadge.layer?.cornerRadius = Theme.radiusMD
        countBadge.isBezeled = false
        countBadge.drawsBackground = false
        countBadge.textColor = accentColor
        addSubview(countBadge)

        self.textField = titleField

        NSLayoutConstraint.activate([
            faviconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.spacingSM),
            faviconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            faviconView.widthAnchor.constraint(equalToConstant: 16),
            faviconView.heightAnchor.constraint(equalToConstant: 16),

            titleField.leadingAnchor.constraint(equalTo: faviconView.trailingAnchor, constant: Theme.spacingSM),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleField.trailingAnchor.constraint(lessThanOrEqualTo: countBadge.leadingAnchor, constant: -Theme.spacingSM),

            countBadge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.spacingMD),
            countBadge.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    func configure(title: String, unreadCount: Int, isMuted: Bool, hasError: Bool, siteHost: String?) {
        // Load favicon async
        if let host = siteHost, let faviconURL = URL(string: "https://www.google.com/s2/favicons?domain=\(host)&sz=32") {
            faviconView.isHidden = false
            Task {
                if let image = await ImageCache.shared.image(for: faviconURL) {
                    await MainActor.run { self.faviconView.image = image }
                }
            }
        } else {
            faviconView.isHidden = true
        }
        var displayTitle = title
        if hasError { displayTitle = "⚠ " + title }
        titleField.stringValue = displayTitle
        titleField.font = .systemFont(ofSize: 13, weight: unreadCount > 0 ? .medium : .regular)
        titleField.textColor = hasError ? .systemOrange : (isMuted ? .tertiaryLabelColor : .labelColor)

        if unreadCount > 0 {
            countBadge.stringValue = "\(unreadCount)"
            countBadge.font = Theme.badgeFont
            countBadge.isHidden = false
        } else {
            countBadge.isHidden = true
        }
    }
}

// MARK: - Context Menu

extension SidebarViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let clickedRow = outlineView.clickedRow
        guard clickedRow >= 0 else { return }
        let item = outlineView.item(atRow: clickedRow)

        if let feedItem = item as? FeedItem {
            let markReadItem = NSMenuItem(title: "Mark All as Read", action: #selector(contextMarkAllRead(_:)), keyEquivalent: "")
            markReadItem.representedObject = feedItem.viewModel.id
            markReadItem.target = self
            menu.addItem(markReadItem)

            menu.addItem(.separator())

            let deleteItem = NSMenuItem(title: "Remove Feed", action: #selector(contextDeleteFeed(_:)), keyEquivalent: "")
            deleteItem.representedObject = feedItem.viewModel.id
            deleteItem.target = self
            menu.addItem(deleteItem)
        }

        if let svItem = item as? SmartViewItem, svItem.smartView == .inbox {
            let markAllItem = NSMenuItem(title: "Mark All as Read", action: #selector(contextMarkAllReadGlobal(_:)), keyEquivalent: "")
            markAllItem.target = self
            menu.addItem(markAllItem)
        }
    }

    @objc private func contextDeleteFeed(_ sender: NSMenuItem) {
        guard let feedId = sender.representedObject as? Int64 else { return }
        let alert = NSAlert()
        alert.messageText = "Remove Feed?"
        alert.informativeText = "This will delete the feed and all its items."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        guard let window = view.window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.onDeleteFeed?(feedId)
        }
    }

    @objc private func contextMarkAllRead(_ sender: NSMenuItem) {
        guard let feedId = sender.representedObject as? Int64 else { return }
        onMarkAllRead?(feedId)
    }

    @objc private func contextMarkAllReadGlobal(_ sender: NSMenuItem) {
        onMarkAllReadGlobal?()
    }
}
