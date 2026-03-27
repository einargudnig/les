import Cocoa

class FeedsViewController: NSViewController {
    var onFeedSelected: ((Int64?) -> Void)?
    private(set) var outlineView: NSOutlineView!
    private var scrollView: NSScrollView!

    private var feeds: [FeedRecord.RowViewModel] = []
    private var folderMap: [(folder: String?, feeds: [FeedRecord.RowViewModel])] = []

    // Warm accent for unread counts
    private let accentColor = NSColor(calibratedRed: 0.545, green: 0.341, blue: 0.165, alpha: 1.0)

    var selectedFeedId: Int64? {
        let row = outlineView.selectedRow
        guard row >= 0 else { return nil }
        if let vm = outlineView.item(atRow: row) as? FeedRecord.RowViewModel {
            return vm.id
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

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("FeedColumn"))
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
        reloadFeeds()
    }

    func reloadFeeds() {
        do {
            let feedStore = FeedStore(db: DatabaseManager.shared.dbPool)
            feeds = try feedStore.listFeeds()
            buildFolderMap()
            outlineView.reloadData()

            // Expand all folders
            for group in folderMap {
                outlineView.expandItem(group.folder ?? "__all__")
            }
        } catch {}
    }

    private func buildFolderMap() {
        var grouped: [String: [FeedRecord.RowViewModel]] = [:]
        var noFolder: [FeedRecord.RowViewModel] = []

        for feed in feeds {
            if let folder = feed.folder {
                grouped[folder, default: []].append(feed)
            } else {
                noFolder.append(feed)
            }
        }

        folderMap = []
        if !noFolder.isEmpty {
            folderMap.append((folder: nil, feeds: noFolder))
        }
        for folder in grouped.keys.sorted() {
            folderMap.append((folder: folder, feeds: grouped[folder]!))
        }
    }

    // MARK: - Vim navigation

    func selectNextFeed() {
        let row = outlineView.selectedRow
        let nextRow = row + 1
        if nextRow < outlineView.numberOfRows {
            outlineView.selectRowIndexes(IndexSet(integer: nextRow), byExtendingSelection: false)
            outlineView.scrollRowToVisible(nextRow)
            notifySelection()
        }
    }

    func selectPreviousFeed() {
        let row = outlineView.selectedRow
        let prevRow = row - 1
        if prevRow >= 0 {
            outlineView.selectRowIndexes(IndexSet(integer: prevRow), byExtendingSelection: false)
            outlineView.scrollRowToVisible(prevRow)
            notifySelection()
        }
    }

    private func notifySelection() {
        onFeedSelected?(selectedFeedId)
    }
}

// MARK: - NSOutlineViewDataSource

extension FeedsViewController: NSOutlineViewDataSource {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil {
            if folderMap.count == 1 && folderMap[0].folder == nil {
                return folderMap[0].feeds.count
            }
            return folderMap.count
        }
        if let folderName = item as? String {
            return folderMap.first(where: { ($0.folder ?? "__all__") == folderName })?.feeds.count ?? 0
        }
        return 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil {
            if folderMap.count == 1 && folderMap[0].folder == nil {
                return folderMap[0].feeds[index]
            }
            return folderMap[index].folder ?? "__all__"
        }
        if let folderName = item as? String,
           let group = folderMap.first(where: { ($0.folder ?? "__all__") == folderName }) {
            return group.feeds[index]
        }
        return ""
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        return item is String
    }
}

// MARK: - NSOutlineViewDelegate

extension FeedsViewController: NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if let folderName = item as? String {
            let cellID = NSUserInterfaceItemIdentifier("FolderCell")
            let cell = outlineView.makeView(withIdentifier: cellID, owner: self) as? NSTableCellView
                ?? makeFolderCell(identifier: cellID)
            cell.textField?.stringValue = (folderName == "__all__" ? "Feeds" : folderName).uppercased()
            return cell
        }

        if let feed = item as? FeedRecord.RowViewModel {
            let cellID = NSUserInterfaceItemIdentifier("FeedCell")
            let cell = outlineView.makeView(withIdentifier: cellID, owner: self) as? FeedCellView
                ?? FeedCellView(identifier: cellID, accentColor: accentColor)
            cell.configure(title: feed.title, unreadCount: feed.unreadCount, isMuted: feed.isMuted)
            return cell
        }

        return nil
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        notifySelection()
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

// MARK: - Custom feed cell

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
