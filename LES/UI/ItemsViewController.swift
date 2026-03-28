import Cocoa

class ItemsViewController: NSViewController {
    var onItemSelected: ((String) -> Void)?
    private(set) var tableView: NSTableView!
    private var scrollView: NSScrollView!
    private var searchField: NSSearchField!

    private var items: [ItemRecord.RowViewModel] = []
    private var currentFeedId: Int64?
    private var currentFilter: ItemFilter = .all
    private var currentSearch: String?

    private let relativeDateFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    private let absoluteDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d MMM"
        return f
    }()

    var selectedItemId: String? {
        let row = tableView.selectedRow
        guard row >= 0 && row < items.count else { return nil }
        return items[row].id
    }

    override func loadView() {
        let container = NSView()
        container.wantsLayer = true

        // Search field at top — refined styling
        searchField = NSSearchField()
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholderString = "Search"
        searchField.font = .systemFont(ofSize: 12, weight: .regular)
        searchField.focusRingType = .none
        searchField.wantsLayer = true
        searchField.layer?.cornerRadius = 8
        searchField.target = self
        searchField.action = #selector(searchChanged(_:))
        container.addSubview(searchField)

        // Table view
        scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false

        tableView = NSTableView()
        tableView.rowHeight = 56
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.style = .plain
        tableView.selectionHighlightStyle = .regular
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.gridStyleMask = []
        tableView.headerView = nil

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("ItemColumn"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)

        tableView.delegate = self
        tableView.dataSource = self

        scrollView.documentView = tableView
        container.addSubview(scrollView)

        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            searchField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            searchField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            searchField.heightAnchor.constraint(equalToConstant: 24),

            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 10),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])

        self.view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scrollViewDidScroll(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
        scrollView.contentView.postsBoundsChangedNotifications = true
    }

    func showItems(forFeedId feedId: Int64?) {
        currentFeedId = feedId
        currentFilter = .all
        loadItems(append: false)
    }

    func showItems(forFilter filter: ItemFilter) {
        currentFeedId = nil
        currentFilter = filter
        loadItems(append: false)
    }

    func setFilter(_ filter: ItemFilter) {
        currentFilter = filter
        loadItems(append: false)
    }

    func reload() {
        loadItems(append: false)
    }

    func focusSearch() {
        view.window?.makeFirstResponder(searchField)
    }

    @objc private func searchChanged(_ sender: NSSearchField) {
        currentSearch = sender.stringValue.isEmpty ? nil : sender.stringValue
        loadItems(append: false)
    }

    private func loadItems(append: Bool) {
        do {
            let store = ItemStore(db: DatabaseManager.shared.dbPool)
            let cursor: TimeInterval? = append ? items.last?.publishedAt : nil
            let newItems = try store.listItems(
                feedId: currentFeedId,
                filter: currentFilter,
                search: currentSearch,
                beforePublishedAt: cursor,
                limit: 200
            )
            if append {
                items.append(contentsOf: newItems)
            } else {
                items = newItems
            }
            tableView.reloadData()
        } catch {
            // Silently handle
        }
    }

    @objc private func scrollViewDidScroll(_ notification: Notification) {
        let visibleRect = scrollView.contentView.documentVisibleRect
        let contentHeight = scrollView.documentView?.frame.height ?? 0
        if visibleRect.maxY > contentHeight - 100 {
            loadItems(append: true)
        }
    }

    // MARK: - Date formatting

    private func formatDate(_ ts: TimeInterval) -> String {
        let date = Date(timeIntervalSince1970: ts)
        let elapsed = Date().timeIntervalSince(date)

        if elapsed < 86400 {
            return relativeDateFormatter.localizedString(for: date, relativeTo: Date())
        } else if elapsed < 86400 * 7 {
            return relativeDateFormatter.localizedString(for: date, relativeTo: Date())
        } else {
            return absoluteDateFormatter.string(from: date)
        }
    }

    // MARK: - Vim navigation support

    func selectNextItem() {
        let row = tableView.selectedRow
        let next = row + 1
        if next < items.count {
            tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
            tableView.scrollRowToVisible(next)
            notifySelection()
        }
    }

    func selectPreviousItem() {
        let row = tableView.selectedRow
        let prev = row - 1
        if prev >= 0 {
            tableView.selectRowIndexes(IndexSet(integer: prev), byExtendingSelection: false)
            tableView.scrollRowToVisible(prev)
            notifySelection()
        }
    }

    func selectFirstItem() {
        guard !items.isEmpty else { return }
        tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        tableView.scrollRowToVisible(0)
        notifySelection()
    }

    func selectLastItem() {
        guard !items.isEmpty else { return }
        let last = items.count - 1
        tableView.selectRowIndexes(IndexSet(integer: last), byExtendingSelection: false)
        tableView.scrollRowToVisible(last)
        notifySelection()
    }

    func selectNextUnread() {
        let startRow = max(tableView.selectedRow + 1, 0)
        for i in startRow..<items.count {
            if !items[i].isRead {
                tableView.selectRowIndexes(IndexSet(integer: i), byExtendingSelection: false)
                tableView.scrollRowToVisible(i)
                notifySelection()
                return
            }
        }
    }

    func selectPreviousUnread() {
        let startRow = max(tableView.selectedRow - 1, 0)
        for i in stride(from: startRow, through: 0, by: -1) {
            if !items[i].isRead {
                tableView.selectRowIndexes(IndexSet(integer: i), byExtendingSelection: false)
                tableView.scrollRowToVisible(i)
                notifySelection()
                return
            }
        }
    }

    func toggleReadCurrent() {
        guard let id = selectedItemId else { return }
        try? ItemStore(db: DatabaseManager.shared.dbPool).toggleRead(id: id)
        loadItems(append: false)
    }

    func toggleStarCurrent() {
        guard let id = selectedItemId else { return }
        try? ItemStore(db: DatabaseManager.shared.dbPool).toggleStar(id: id)
        loadItems(append: false)
    }

    func openCurrentInBrowser() {
        guard let id = selectedItemId else { return }
        let content = try? ItemStore(db: DatabaseManager.shared.dbPool).loadItemContent(id: id)
        if let urlStr = content?.url, let url = URL(string: urlStr) {
            NSWorkspace.shared.open(url)
        }
    }

    private func notifySelection() {
        guard let id = selectedItemId else { return }
        try? ItemStore(db: DatabaseManager.shared.dbPool).markRead(id: id)
        onItemSelected?(id)
    }
}

// MARK: - NSTableViewDataSource

extension ItemsViewController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        return items.count
    }
}

// MARK: - NSTableViewDelegate

extension ItemsViewController: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < items.count else { return nil }
        let item = items[row]

        let cellID = NSUserInterfaceItemIdentifier("ItemCell")
        let cell = tableView.makeView(withIdentifier: cellID, owner: self) as? ItemCellView
            ?? ItemCellView(identifier: cellID)

        let subtitle: String?
        if item.isBookmark {
            subtitle = item.url.flatMap { URL(string: $0)?.host }
        } else {
            subtitle = item.author
        }

        cell.configure(
            title: item.title,
            date: item.publishedAt.map { formatDate($0) } ?? "",
            subtitle: subtitle,
            isRead: item.isRead,
            isStarred: item.isStarred,
            isBookmark: item.isBookmark
        )

        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        notifySelection()
    }
}

// MARK: - Custom cell view

private class ItemCellView: NSTableCellView {
    private let titleField = NSTextField(labelWithString: "")
    private let dateField = NSTextField(labelWithString: "")
    private let authorField = NSTextField(labelWithString: "")
    private let unreadDot = NSView()
    private let starLabel = NSTextField(labelWithString: "")
    private let bookmarkLabel = NSTextField(labelWithString: "")

    convenience init(identifier: NSUserInterfaceItemIdentifier) {
        self.init()
        self.identifier = identifier

        for v in [titleField, dateField, authorField, unreadDot, starLabel, bookmarkLabel] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }

        titleField.lineBreakMode = .byTruncatingTail
        titleField.maximumNumberOfLines = 1

        dateField.lineBreakMode = .byClipping
        dateField.alignment = .right
        dateField.setContentCompressionResistancePriority(.required, for: .horizontal)
        dateField.setContentHuggingPriority(.required, for: .horizontal)

        authorField.lineBreakMode = .byTruncatingTail
        authorField.maximumNumberOfLines = 1

        unreadDot.wantsLayer = true
        unreadDot.layer?.cornerRadius = 3
        unreadDot.layer?.backgroundColor = NSColor(calibratedRed: 0.545, green: 0.341, blue: 0.165, alpha: 1.0).cgColor

        starLabel.font = .systemFont(ofSize: 11)
        starLabel.textColor = NSColor(calibratedRed: 0.76, green: 0.60, blue: 0.32, alpha: 1.0)

        bookmarkLabel.font = .systemFont(ofSize: 11)
        bookmarkLabel.textColor = NSColor(calibratedRed: 0.545, green: 0.341, blue: 0.165, alpha: 1.0)

        NSLayoutConstraint.activate([
            // Unread dot — left edge
            unreadDot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            unreadDot.centerYAnchor.constraint(equalTo: centerYAnchor),
            unreadDot.widthAnchor.constraint(equalToConstant: 6),
            unreadDot.heightAnchor.constraint(equalToConstant: 6),

            // Title — top row
            titleField.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            titleField.leadingAnchor.constraint(equalTo: unreadDot.trailingAnchor, constant: 8),
            titleField.trailingAnchor.constraint(lessThanOrEqualTo: dateField.leadingAnchor, constant: -8),

            // Date — top right
            dateField.firstBaselineAnchor.constraint(equalTo: titleField.firstBaselineAnchor),
            dateField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),

            // Star + bookmark + author — bottom row
            starLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            starLabel.leadingAnchor.constraint(equalTo: unreadDot.trailingAnchor, constant: 8),

            bookmarkLabel.firstBaselineAnchor.constraint(equalTo: starLabel.firstBaselineAnchor),
            bookmarkLabel.leadingAnchor.constraint(equalTo: starLabel.trailingAnchor, constant: 2),

            authorField.firstBaselineAnchor.constraint(equalTo: starLabel.firstBaselineAnchor),
            authorField.leadingAnchor.constraint(equalTo: bookmarkLabel.trailingAnchor, constant: 2),
            authorField.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
        ])
    }

    func configure(title: String, date: String, subtitle: String?, isRead: Bool, isStarred: Bool, isBookmark: Bool) {
        // Title
        titleField.stringValue = title
        titleField.font = .systemFont(ofSize: 13, weight: isRead ? .regular : .medium)
        titleField.textColor = isRead
            ? .secondaryLabelColor
            : .labelColor

        // Date
        dateField.stringValue = date
        dateField.font = .systemFont(ofSize: 11, weight: .regular)
        dateField.textColor = NSColor(calibratedWhite: 0.55, alpha: 1.0)

        // Subtitle (author for RSS, domain for bookmarks)
        authorField.stringValue = subtitle ?? ""
        authorField.font = .systemFont(ofSize: 11, weight: .regular)
        authorField.textColor = NSColor(calibratedWhite: 0.55, alpha: 1.0)

        // Unread dot
        unreadDot.isHidden = isRead

        // Star
        starLabel.stringValue = isStarred ? "★" : ""

        // Bookmark indicator
        bookmarkLabel.stringValue = isBookmark ? "↗" : ""
    }
}
