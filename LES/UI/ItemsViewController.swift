import Cocoa

class ItemsViewController: NSViewController {
    var onItemSelected: ((String) -> Void)?
    var onReadStateChanged: (() -> Void)?
    private(set) var tableView: NSTableView!
    private var scrollView: NSScrollView!
    private var searchField: NSSearchField!

    private var items: [ItemRecord.RowViewModel] = []
    private var currentFeedId: Int64?
    private var currentFilter: ItemFilter = .all
    private var markReadTimer: Timer?
    private var currentSearch: String?
    private var emptyLabel: NSTextField!

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
        searchField.font = Theme.itemDetailFont
        searchField.focusRingType = .none
        searchField.wantsLayer = true
        searchField.layer?.cornerRadius = Theme.radiusLG
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
        tableView.rowHeight = Theme.itemRowHeight
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

        // Context menu
        let menu = NSMenu()
        menu.delegate = self
        tableView.menu = menu

        scrollView.documentView = tableView
        container.addSubview(scrollView)

        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: container.topAnchor, constant: Theme.spacingMD),
            searchField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Theme.spacingMD),
            searchField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Theme.spacingMD),
            searchField.heightAnchor.constraint(equalToConstant: Theme.spacingXL),

            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: Theme.spacingSM),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])

        // Empty state label
        emptyLabel = NSTextField(labelWithString: "No items")
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.font = .systemFont(ofSize: 13, weight: .regular)
        emptyLabel.textColor = Theme.tertiaryText
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true
        container.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
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

    private func reloadKeepingSelection() {
        let previousId = selectedItemId
        loadItems(append: false)
        if let previousId, let index = items.firstIndex(where: { $0.id == previousId }) {
            tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
    }

    func focusSearch() {
        view.window?.makeFirstResponder(searchField)
    }

    private func showToast(_ message: String) {
        guard let wc = view.window?.windowController as? MainWindowController else { return }
        let previous = view.window?.title ?? "les"
        view.window?.title = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            wc.updateWindowTitle()
        }
    }

    private func updateEmptyState() {
        if items.isEmpty {
            let message: String
            if currentSearch != nil && !currentSearch!.isEmpty {
                message = "No results"
            } else {
                switch currentFilter {
                case .unread: message = "All caught up"
                case .starred: message = "No starred items"
                case .readingList: message = "No bookmarks yet"
                case .today: message = "Nothing new today"
                default: message = "No items"
                }
            }
            emptyLabel.stringValue = message
            emptyLabel.isHidden = false
        } else {
            emptyLabel.isHidden = true
        }
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
            updateEmptyState()
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
        guard let id = selectedItemId, let row = items.firstIndex(where: { $0.id == id }) else { return }
        let wasRead = items[row].isRead
        try? ItemStore(db: DatabaseManager.shared.dbPool).toggleRead(id: id)
        reloadKeepingSelection()
        onReadStateChanged?()
        showToast(wasRead ? "Marked unread" : "Marked read")
    }

    func toggleStarCurrent() {
        guard let id = selectedItemId, let row = items.firstIndex(where: { $0.id == id }) else { return }
        let wasStarred = items[row].isStarred
        try? ItemStore(db: DatabaseManager.shared.dbPool).toggleStar(id: id)
        reloadKeepingSelection()
        onReadStateChanged?()
        showToast(wasStarred ? "Unstarred" : "Starred")
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
        onItemSelected?(id)

        // Mark read after a short delay — avoids marking items when just browsing
        markReadTimer?.invalidate()
        markReadTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
            try? ItemStore(db: DatabaseManager.shared.dbPool).markRead(id: id)
            self?.reloadKeepingSelection()
            self?.onReadStateChanged?()
        }
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

// MARK: - Context Menu

extension ItemsViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let clickedRow = tableView.clickedRow
        guard clickedRow >= 0, clickedRow < items.count else { return }
        let item = items[clickedRow]

        // Toggle read
        let readTitle = item.isRead ? "Mark as Unread" : "Mark as Read"
        let readItem = NSMenuItem(title: readTitle, action: #selector(contextToggleRead(_:)), keyEquivalent: "")
        readItem.tag = clickedRow
        readItem.target = self
        menu.addItem(readItem)

        // Toggle star
        let starTitle = item.isStarred ? "Unstar" : "Star"
        let starItem = NSMenuItem(title: starTitle, action: #selector(contextToggleStar(_:)), keyEquivalent: "")
        starItem.tag = clickedRow
        starItem.target = self
        menu.addItem(starItem)

        menu.addItem(.separator())

        // Open in browser
        if item.url != nil {
            let openItem = NSMenuItem(title: "Open in Browser", action: #selector(contextOpenInBrowser(_:)), keyEquivalent: "")
            openItem.tag = clickedRow
            openItem.target = self
            menu.addItem(openItem)

            // Copy link
            let copyItem = NSMenuItem(title: "Copy Link", action: #selector(contextCopyLink(_:)), keyEquivalent: "")
            copyItem.tag = clickedRow
            copyItem.target = self
            menu.addItem(copyItem)

            menu.addItem(.separator())
        }

        // Delete (bookmarks only)
        if item.isBookmark {
            let deleteItem = NSMenuItem(title: "Remove Bookmark", action: #selector(contextDeleteItem(_:)), keyEquivalent: "")
            deleteItem.tag = clickedRow
            deleteItem.target = self
            menu.addItem(deleteItem)
        }
    }

    @objc private func contextToggleRead(_ sender: NSMenuItem) {
        let row = sender.tag
        guard row < items.count else { return }
        try? ItemStore(db: DatabaseManager.shared.dbPool).toggleRead(id: items[row].id)
        loadItems(append: false)
        onReadStateChanged?()
    }

    @objc private func contextToggleStar(_ sender: NSMenuItem) {
        let row = sender.tag
        guard row < items.count else { return }
        try? ItemStore(db: DatabaseManager.shared.dbPool).toggleStar(id: items[row].id)
        loadItems(append: false)
        onReadStateChanged?()
    }

    @objc private func contextOpenInBrowser(_ sender: NSMenuItem) {
        let row = sender.tag
        guard row < items.count, let urlStr = items[row].url, let url = URL(string: urlStr) else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func contextCopyLink(_ sender: NSMenuItem) {
        let row = sender.tag
        guard row < items.count, let urlStr = items[row].url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(urlStr, forType: .string)
        showToast("Link copied")
    }

    @objc private func contextDeleteItem(_ sender: NSMenuItem) {
        let row = sender.tag
        guard row < items.count else { return }
        try? ItemStore(db: DatabaseManager.shared.dbPool).deleteItem(id: items[row].id)
        loadItems(append: false)
        onReadStateChanged?()
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
        unreadDot.layer?.backgroundColor = Theme.accent.cgColor

        starLabel.font = .systemFont(ofSize: 11)
        starLabel.textColor = Theme.accent

        bookmarkLabel.font = .systemFont(ofSize: 11)
        bookmarkLabel.textColor = Theme.accentSubtle

        NSLayoutConstraint.activate([
            // Unread dot — left edge
            unreadDot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.spacingMD),
            unreadDot.centerYAnchor.constraint(equalTo: centerYAnchor),
            unreadDot.widthAnchor.constraint(equalToConstant: 6),
            unreadDot.heightAnchor.constraint(equalToConstant: 6),

            // Title — top row
            titleField.topAnchor.constraint(equalTo: topAnchor, constant: Theme.spacingSM + 2),
            titleField.leadingAnchor.constraint(equalTo: unreadDot.trailingAnchor, constant: Theme.spacingSM),
            titleField.trailingAnchor.constraint(lessThanOrEqualTo: dateField.leadingAnchor, constant: -Theme.spacingSM),

            // Date — top right
            dateField.firstBaselineAnchor.constraint(equalTo: titleField.firstBaselineAnchor),
            dateField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.spacingMD),

            // Star + bookmark + author — bottom row
            starLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -(Theme.spacingSM + 2)),
            starLabel.leadingAnchor.constraint(equalTo: unreadDot.trailingAnchor, constant: Theme.spacingSM),

            bookmarkLabel.firstBaselineAnchor.constraint(equalTo: starLabel.firstBaselineAnchor),
            bookmarkLabel.leadingAnchor.constraint(equalTo: starLabel.trailingAnchor, constant: Theme.spacingXS),

            authorField.firstBaselineAnchor.constraint(equalTo: starLabel.firstBaselineAnchor),
            authorField.leadingAnchor.constraint(equalTo: bookmarkLabel.trailingAnchor, constant: Theme.spacingXS),
            authorField.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Theme.spacingMD),
        ])
    }

    func configure(title: String, date: String, subtitle: String?, isRead: Bool, isStarred: Bool, isBookmark: Bool) {
        titleField.stringValue = title
        titleField.font = isRead ? Theme.itemTitleFont : Theme.itemTitleFontBold
        titleField.textColor = isRead ? .secondaryLabelColor : .labelColor

        dateField.stringValue = date
        dateField.font = Theme.itemDetailFont
        dateField.textColor = Theme.tertiaryText

        authorField.stringValue = subtitle ?? ""
        authorField.font = Theme.itemDetailFont
        authorField.textColor = Theme.tertiaryText

        unreadDot.isHidden = isRead
        starLabel.stringValue = isStarred ? "★" : ""
        bookmarkLabel.stringValue = isBookmark ? "↗" : ""
    }
}
