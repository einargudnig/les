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

    var icon: String {
        switch self {
        case .inbox: return "\u{1F4E5}"       // 📥
        case .readingList: return "\u{1F4D6}"  // 📖
        case .starred: return "\u{2B50}"       // ⭐
        case .today: return "\u{2600}\u{FE0F}" // ☀️
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
    let viewModel: FeedRecord.RowViewModel

    init(_ viewModel: FeedRecord.RowViewModel) {
        self.viewModel = viewModel
    }
}

// MARK: - SidebarViewController

class SidebarViewController: NSViewController {
    var onSelectionChanged: ((SidebarSelection) -> Void)?
    private(set) var outlineView: NSOutlineView!
    private var scrollView: NSScrollView!

    private let accentColor = NSColor(calibratedRed: 0.545, green: 0.341, blue: 0.165, alpha: 1.0)

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
        outlineView.rowHeight = 28
        outlineView.indentationPerLevel = 14
        outlineView.style = .sourceList

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("SidebarColumn"))
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column

        outlineView.delegate = self
        outlineView.dataSource = self

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

    func reloadData() {
        // Load smart view counts
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
            cell.configure(icon: svItem.smartView.icon, title: svItem.smartView.rawValue, count: svItem.count)
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
            cell.configure(title: feedItem.viewModel.title, unreadCount: feedItem.viewModel.unreadCount, isMuted: feedItem.viewModel.isMuted)
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
            line.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 12),
            line.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -12),
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
        tf.font = .systemFont(ofSize: 10, weight: .semibold)
        tf.textColor = .tertiaryLabelColor
        tf.lineBreakMode = .byTruncatingTail
        cell.addSubview(tf)
        cell.textField = tf
        NSLayoutConstraint.activate([
            tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}

// MARK: - SmartViewCellView

private class SmartViewCellView: NSTableCellView {
    private let iconField = NSTextField(labelWithString: "")
    private let titleField = NSTextField(labelWithString: "")
    private let countBadge = NSTextField(labelWithString: "")

    convenience init(identifier: NSUserInterfaceItemIdentifier, accentColor: NSColor) {
        self.init()
        self.identifier = identifier

        iconField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconField)

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

        NSLayoutConstraint.activate([
            iconField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            iconField.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconField.widthAnchor.constraint(equalToConstant: 20),

            titleField.leadingAnchor.constraint(equalTo: iconField.trailingAnchor, constant: 4),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleField.trailingAnchor.constraint(lessThanOrEqualTo: countBadge.leadingAnchor, constant: -6),

            countBadge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            countBadge.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    func configure(icon: String, title: String, count: Int) {
        iconField.stringValue = icon
        iconField.font = .systemFont(ofSize: 13)
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
    private let titleField = NSTextField(labelWithString: "")
    private let countBadge = NSTextField(labelWithString: "")

    convenience init(identifier: NSUserInterfaceItemIdentifier, accentColor: NSColor) {
        self.init()
        self.identifier = identifier

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

        NSLayoutConstraint.activate([
            titleField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleField.trailingAnchor.constraint(lessThanOrEqualTo: countBadge.leadingAnchor, constant: -6),

            countBadge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            countBadge.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    func configure(title: String, unreadCount: Int, isMuted: Bool) {
        titleField.stringValue = title
        titleField.font = .systemFont(ofSize: 13, weight: unreadCount > 0 ? .medium : .regular)
        titleField.textColor = isMuted ? .tertiaryLabelColor : .labelColor

        if unreadCount > 0 {
            countBadge.stringValue = "\(unreadCount)"
            countBadge.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            countBadge.isHidden = false
        } else {
            countBadge.isHidden = true
        }
    }
}
