# Sidebar Redesign + Read-It-Later Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Transform LES into a unified reading app with an activity-based sidebar, read-it-later bookmarks, and inline image support.

**Architecture:** The `items` table becomes the single content store for both RSS and bookmarks (distinguished by `feedId` vs `bookmarkId`). A new `SidebarViewController` replaces `FeedsViewController` with smart views (Inbox, Reading List, Starred, Today) above a divider, feeds below. A `ReadabilityExtractor` fetches and extracts article content from arbitrary URLs. The `ReaderRenderer` gains async image loading with placeholder support.

**Tech Stack:** Swift, AppKit, GRDB, URLSession, CryptoKit, XMLDocument (for HTML parsing)

---

### Task 1: Database Migration — bookmarks table + items schema change

**Files:**
- Modify: `LES/Database/DatabaseManager.swift` (add v2 migration)
- Modify: `LES/Database/ItemRecord.swift` (make feedId optional, add bookmarkId)
- Create: `LES/Database/BookmarkRecord.swift`

- [ ] **Step 1: Add BookmarkRecord model**

Create `LES/Database/BookmarkRecord.swift`:

```swift
import Foundation
import GRDB

struct BookmarkRecord: Codable, FetchableRecord, PersistableRecord, Identifiable {
    static let databaseTableName = "bookmarks"

    var id: Int64?
    var url: String
    var siteName: String?
    var extractedAt: TimeInterval?
    var createdAt: TimeInterval
    var updatedAt: TimeInterval

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

extension BookmarkRecord: MutablePersistableRecord {}
```

- [ ] **Step 2: Update ItemRecord — make feedId nullable, add bookmarkId**

In `LES/Database/ItemRecord.swift`, change:

```swift
// Change feedId from Int64 to Int64?
var feedId: Int64?
// Add after feedId:
var bookmarkId: Int64?

// Add computed property:
var isBookmark: Bool { bookmarkId != nil }
```

Also update `stableID` to handle bookmark IDs:

```swift
static func bookmarkStableID(url: String) -> String {
    let input = "bookmark:\(url)"
    let digest = SHA256.hash(data: Data(input.utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
}
```

And update `RowViewModel`:

```swift
struct RowViewModel {
    let id: String
    let title: String
    let author: String?
    let publishedAt: TimeInterval?
    let isRead: Bool
    let isStarred: Bool
    let isBookmark: Bool
}
```

- [ ] **Step 3: Add v2 migration to DatabaseManager**

In `LES/Database/DatabaseManager.swift`, add after the v1 migration block (before `return migrator`):

```swift
migrator.registerMigration("v2_bookmarks") { db in
    try db.create(table: "bookmarks") { t in
        t.autoIncrementedPrimaryKey("id")
        t.column("url", .text).notNull().unique()
        t.column("siteName", .text)
        t.column("extractedAt", .double)
        t.column("createdAt", .double).notNull()
        t.column("updatedAt", .double).notNull()
    }

    // Add bookmarkId column to items
    try db.alter(table: "items") { t in
        t.add(column: "bookmarkId", .integer)
            .references("bookmarks", onDelete: .cascade)
    }

    // Make feedId nullable — SQLite ALTER can't change nullability,
    // but the column was created as NOT NULL. We need to recreate.
    // GRDB handles this: we create a new table, copy data, swap.
    try db.create(table: "items_new") { t in
        t.primaryKey("id", .text)
        t.column("feedId", .integer)
            .references("feeds", onDelete: .cascade)
        t.column("bookmarkId", .integer)
            .references("bookmarks", onDelete: .cascade)
        t.column("title", .text)
        t.column("author", .text)
        t.column("url", .text)
        t.column("externalId", .text)
        t.column("publishedAt", .double)
        t.column("updatedAt", .double)
        t.column("summaryHTML", .text)
        t.column("contentHTML", .text)
        t.column("readAt", .double)
        t.column("starredAt", .double)
    }

    try db.execute(sql: """
        INSERT INTO items_new (id, feedId, title, author, url, externalId,
            publishedAt, updatedAt, summaryHTML, contentHTML, readAt, starredAt)
        SELECT id, feedId, title, author, url, externalId,
            publishedAt, updatedAt, summaryHTML, contentHTML, readAt, starredAt
        FROM items
    """)

    try db.drop(table: "items")
    try db.rename(table: "items_new", to: "items")

    // Recreate indexes
    try db.create(index: "idx_items_feed_published", on: "items", columns: ["feedId", "publishedAt"])
    try db.create(index: "idx_items_readAt", on: "items", columns: ["readAt"])
    try db.create(index: "idx_items_starredAt", on: "items", columns: ["starredAt"])
    try db.create(index: "idx_items_bookmarkId", on: "items", columns: ["bookmarkId"])
}
```

- [ ] **Step 4: Update IngestService to pass bookmarkId: nil**

In `LES/Ingest/IngestService.swift`, update the ItemRecord constructor (around line 50):

```swift
let item = ItemRecord(
    id: stableId,
    feedId: feedId,
    bookmarkId: nil,
    title: parsedItem.title,
    author: parsedItem.author,
    url: parsedItem.link,
    externalId: parsedItem.externalId,
    publishedAt: parsedItem.publishedAt,
    updatedAt: Date().timeIntervalSince1970,
    summaryHTML: parsedItem.summaryHTML,
    contentHTML: parsedItem.contentHTML
)
```

- [ ] **Step 5: Build and verify**

Run: `swift build`
Expected: Compiles with no errors.

- [ ] **Step 6: Commit**

```bash
git add LES/Database/BookmarkRecord.swift LES/Database/DatabaseManager.swift LES/Database/ItemRecord.swift LES/Ingest/IngestService.swift
git commit -m "feat: add bookmarks table and make items support both feeds and bookmarks"
```

---

### Task 2: BookmarkStore + ItemStore updates

**Files:**
- Create: `LES/Stores/BookmarkStore.swift`
- Modify: `LES/Stores/ItemStore.swift` (add readingList filter, isBookmark to SQL, unread counts for smart views)

- [ ] **Step 1: Create BookmarkStore**

Create `LES/Stores/BookmarkStore.swift`:

```swift
import Foundation
import GRDB

struct BookmarkStore {
    let db: DatabasePool

    @discardableResult
    func insertBookmark(url: String) throws -> BookmarkRecord {
        try db.write { db in
            let now = Date().timeIntervalSince1970
            var bookmark = BookmarkRecord(
                url: url,
                createdAt: now,
                updatedAt: now
            )
            try bookmark.insert(db)
            return bookmark
        }
    }

    func deleteBookmark(id: Int64) throws {
        try db.write { db in
            _ = try BookmarkRecord.deleteOne(db, key: id)
        }
    }

    func bookmarkByURL(_ url: String) throws -> BookmarkRecord? {
        try db.read { db in
            try BookmarkRecord.filter(Column("url") == url).fetchOne(db)
        }
    }

    func updateExtraction(id: Int64, siteName: String?) throws {
        try db.write { db in
            if var bookmark = try BookmarkRecord.fetchOne(db, key: id) {
                bookmark.siteName = siteName
                bookmark.extractedAt = Date().timeIntervalSince1970
                bookmark.updatedAt = Date().timeIntervalSince1970
                try bookmark.update(db)
            }
        }
    }
}
```

- [ ] **Step 2: Update ItemFilter enum**

In `LES/Stores/ItemStore.swift`, update the enum:

```swift
enum ItemFilter {
    case all
    case unread      // Inbox
    case readingList // bookmarkId IS NOT NULL
    case starred
    case today
    case lastSevenDays
}
```

- [ ] **Step 3: Update buildListSQL to include bookmarkId and readingList**

In `LES/Stores/ItemStore.swift`, update `buildListSQL`:

Change the SELECT to include `bookmarkId`:
```swift
var sql = "SELECT id, title, author, publishedAt, readAt, starredAt, bookmarkId FROM items"
```

Add the readingList case in the filter switch:
```swift
case .readingList:
    conditions.append("bookmarkId IS NOT NULL")
```

- [ ] **Step 4: Update listItems to map isBookmark**

In the `listItems` function, update the row mapping:

```swift
return directRows.map { row in
    ItemRecord.RowViewModel(
        id: row["id"],
        title: row["title"] ?? "Untitled",
        author: row["author"],
        publishedAt: row["publishedAt"],
        isRead: row["readAt"] != nil,
        isStarred: row["starredAt"] != nil,
        isBookmark: row["bookmarkId"] != nil
    )
}
```

- [ ] **Step 5: Add smart view unread counts**

Add to `ItemStore`:

```swift
func inboxUnreadCount() throws -> Int {
    try db.read { db in
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM items WHERE readAt IS NULL") ?? 0
    }
}

func readingListUnreadCount() throws -> Int {
    try db.read { db in
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM items WHERE bookmarkId IS NOT NULL AND readAt IS NULL") ?? 0
    }
}

func starredCount() throws -> Int {
    try db.read { db in
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM items WHERE starredAt IS NOT NULL") ?? 0
    }
}

func todayUnreadCount() throws -> Int {
    try db.read { db in
        let dayStart = Date().timeIntervalSince1970 - 86400
        return try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM items WHERE readAt IS NULL AND publishedAt >= ?", arguments: [dayStart]) ?? 0
    }
}
```

- [ ] **Step 6: Build and verify**

Run: `swift build`
Expected: Compiles with no errors.

- [ ] **Step 7: Commit**

```bash
git add LES/Stores/BookmarkStore.swift LES/Stores/ItemStore.swift
git commit -m "feat: add BookmarkStore and update ItemStore for smart views"
```

---

### Task 3: Readability Content Extractor

**Files:**
- Create: `LES/Extraction/ReadabilityExtractor.swift`

- [ ] **Step 1: Create the extractor**

Create `LES/Extraction/ReadabilityExtractor.swift`:

```swift
import Foundation

struct ExtractedArticle {
    var title: String?
    var author: String?
    var contentHTML: String?
    var siteName: String?
    var publishedAt: TimeInterval?
}

final class ReadabilityExtractor {
    func extract(html: String, url: URL) -> ExtractedArticle {
        let doc: XMLDocument
        do {
            doc = try XMLDocument(xmlString: html, options: [.documentTidyHTML, .nodePreserveWhitespace])
        } catch {
            return ExtractedArticle()
        }

        let title = extractTitle(doc: doc)
        let author = extractAuthor(doc: doc)
        let siteName = extractSiteName(doc: doc)
        let contentHTML = extractContent(doc: doc)

        return ExtractedArticle(
            title: title,
            author: author,
            contentHTML: contentHTML,
            siteName: siteName
        )
    }

    // MARK: - Title

    private func extractTitle(doc: XMLDocument) -> String? {
        // Try og:title first
        if let ogTitle = metaContent(doc: doc, property: "og:title") {
            return ogTitle
        }
        // Try <title>
        if let title = try? doc.nodes(forXPath: "//title").first?.stringValue,
           !title.isEmpty {
            return title.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Try first h1
        if let h1 = try? doc.nodes(forXPath: "//h1").first?.stringValue {
            return h1.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    // MARK: - Author

    private func extractAuthor(doc: XMLDocument) -> String? {
        if let author = metaContent(doc: doc, name: "author") {
            return author
        }
        if let author = metaContent(doc: doc, property: "article:author") {
            return author
        }
        // Look for common byline patterns
        let bylineSelectors = [
            "//*[contains(@class, 'byline')]",
            "//*[contains(@class, 'author')]",
            "//*[@rel='author']",
        ]
        for selector in bylineSelectors {
            if let node = try? doc.nodes(forXPath: selector).first,
               let text = node.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty, text.count < 100 {
                return text
            }
        }
        return nil
    }

    // MARK: - Site Name

    private func extractSiteName(doc: XMLDocument) -> String? {
        metaContent(doc: doc, property: "og:site_name")
    }

    // MARK: - Content Extraction

    private func extractContent(doc: XMLDocument) -> String? {
        // Strategy: find the best content node by scoring

        // 1. Try <article> tag first
        if let article = try? doc.nodes(forXPath: "//article").first as? XMLElement {
            return cleanedHTML(from: article)
        }

        // 2. Try [role="main"]
        if let main = try? doc.nodes(forXPath: "//*[@role='main']").first as? XMLElement {
            return cleanedHTML(from: main)
        }

        // 3. Try <main> tag
        if let main = try? doc.nodes(forXPath: "//main").first as? XMLElement {
            return cleanedHTML(from: main)
        }

        // 4. Score divs by text density
        guard let body = try? doc.nodes(forXPath: "//body").first as? XMLElement else {
            return nil
        }

        var bestNode: XMLElement?
        var bestScore: Double = 0

        scoreNodes(element: body, bestNode: &bestNode, bestScore: &bestScore)

        if let best = bestNode {
            return cleanedHTML(from: best)
        }

        return nil
    }

    private func scoreNodes(element: XMLElement, bestNode: inout XMLElement?, bestScore: inout Double) {
        let tagName = element.name?.lowercased() ?? ""

        // Skip non-content tags
        let skipTags: Set = ["nav", "footer", "header", "aside", "script", "style", "form", "noscript"]
        if skipTags.contains(tagName) { return }

        // Skip elements with non-content classes
        let classAttr = (element.attribute(forName: "class")?.stringValue ?? "").lowercased()
        let idAttr = (element.attribute(forName: "id")?.stringValue ?? "").lowercased()
        let skipPatterns = ["nav", "footer", "sidebar", "menu", "comment", "widget", "ad-", "social", "share", "related"]
        if skipPatterns.contains(where: { classAttr.contains($0) || idAttr.contains($0) }) {
            return
        }

        if tagName == "div" || tagName == "section" {
            let text = element.stringValue ?? ""
            let textLength = Double(text.count)

            // Count <p> children
            let pCount = Double((try? element.nodes(forXPath: ".//p")).map(\.count) ?? 0)

            // Score: text length + bonus for <p> tags
            let score = textLength * 0.1 + pCount * 50

            if score > bestScore {
                bestScore = score
                bestNode = element
            }
        }

        // Recurse into children
        for child in element.children ?? [] {
            if let childElement = child as? XMLElement {
                scoreNodes(element: childElement, bestNode: &bestNode, bestScore: &bestScore)
            }
        }
    }

    // MARK: - HTML Cleaning

    private func cleanedHTML(from element: XMLElement) -> String? {
        removeUnwantedElements(from: element)
        return element.xmlString(options: [.nodePreserveWhitespace])
    }

    private func removeUnwantedElements(from element: XMLElement) {
        let removeTags: Set = ["script", "style", "nav", "footer", "aside", "header",
                                "iframe", "noscript", "form", "svg"]
        let removeClasses = ["nav", "footer", "sidebar", "menu", "comment", "widget",
                             "ad-", "social", "share", "related", "popup", "modal"]

        var toRemove: [XMLNode] = []

        for child in element.children ?? [] {
            guard let childElement = child as? XMLElement else { continue }
            let tag = childElement.name?.lowercased() ?? ""
            let cls = (childElement.attribute(forName: "class")?.stringValue ?? "").lowercased()
            let idVal = (childElement.attribute(forName: "id")?.stringValue ?? "").lowercased()

            if removeTags.contains(tag) {
                toRemove.append(child)
            } else if removeClasses.contains(where: { cls.contains($0) || idVal.contains($0) }) {
                toRemove.append(child)
            } else {
                removeUnwantedElements(from: childElement)
            }
        }

        for node in toRemove {
            element.removeChild(at: node.index)
        }
    }

    // MARK: - Meta Helpers

    private func metaContent(doc: XMLDocument, property: String) -> String? {
        let xpath = "//meta[@property='\(property)']/@content"
        if let val = try? doc.nodes(forXPath: xpath).first?.stringValue,
           !val.isEmpty {
            return val.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    private func metaContent(doc: XMLDocument, name: String) -> String? {
        let xpath = "//meta[@name='\(name)']/@content"
        if let val = try? doc.nodes(forXPath: xpath).first?.stringValue,
           !val.isEmpty {
            return val.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }
}
```

- [ ] **Step 2: Build and verify**

Run: `swift build`
Expected: Compiles with no errors.

- [ ] **Step 3: Commit**

```bash
git add LES/Extraction/ReadabilityExtractor.swift
git commit -m "feat: add Readability-based content extractor"
```

---

### Task 4: BookmarkService — fetch, extract, store pipeline

**Files:**
- Create: `LES/Ingest/BookmarkService.swift`

- [ ] **Step 1: Create BookmarkService**

Create `LES/Ingest/BookmarkService.swift`:

```swift
import Foundation
import GRDB
import CryptoKit

actor BookmarkService {
    private let extractor = ReadabilityExtractor()

    func addBookmark(url: String, db: DatabasePool) async throws {
        let bookmarkStore = BookmarkStore(db: db)

        // Check for duplicate
        if try bookmarkStore.bookmarkByURL(url) != nil {
            return // already bookmarked
        }

        // Insert bookmark record immediately
        let bookmark = try bookmarkStore.insertBookmark(url: url)
        guard let bookmarkId = bookmark.id else { return }

        // Fetch and extract
        do {
            let extracted = try await fetchAndExtract(urlString: url)

            // Create item
            let stableId = ItemRecord.bookmarkStableID(url: url)
            let item = ItemRecord(
                id: stableId,
                feedId: nil,
                bookmarkId: bookmarkId,
                title: extracted.title ?? url,
                author: extracted.author,
                url: url,
                publishedAt: extracted.publishedAt ?? Date().timeIntervalSince1970,
                updatedAt: Date().timeIntervalSince1970,
                contentHTML: extracted.contentHTML
            )

            try db.write { db in
                try item.insert(db)
            }

            try bookmarkStore.updateExtraction(id: bookmarkId, siteName: extracted.siteName)
        } catch {
            // Extraction failed — create item with error message
            let stableId = ItemRecord.bookmarkStableID(url: url)
            let errorHTML = """
                <p>Could not extract article content.</p>
                <p><a href="\(url)">Open in browser</a></p>
            """
            let item = ItemRecord(
                id: stableId,
                feedId: nil,
                bookmarkId: bookmarkId,
                title: url,
                url: url,
                publishedAt: Date().timeIntervalSince1970,
                updatedAt: Date().timeIntervalSince1970,
                contentHTML: errorHTML
            )
            try? db.write { db in
                try item.insert(db)
            }
        }
    }

    private func fetchAndExtract(urlString: String) async throws -> ExtractedArticle {
        guard let url = URL(string: urlString) else {
            throw BookmarkError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        request.setValue("text/html", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw BookmarkError.fetchFailed
        }

        // Detect encoding
        let encoding = httpResponse.textEncodingName
            .flatMap { CFStringConvertEncodingToNSStringEncoding(CFStringConvertIANACharSetNameToEncoding($0 as CFString)) }
            .flatMap { String.Encoding(rawValue: $0) }
            ?? .utf8

        guard let html = String(data: data, encoding: encoding) ?? String(data: data, encoding: .utf8) else {
            throw BookmarkError.decodeFailed
        }

        return extractor.extract(html: html, url: url)
    }
}

enum BookmarkError: LocalizedError {
    case invalidURL
    case fetchFailed
    case decodeFailed

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid URL"
        case .fetchFailed: return "Failed to fetch page"
        case .decodeFailed: return "Failed to decode page content"
        }
    }
}
```

- [ ] **Step 2: Build and verify**

Run: `swift build`
Expected: Compiles with no errors.

- [ ] **Step 3: Commit**

```bash
git add LES/Ingest/BookmarkService.swift
git commit -m "feat: add BookmarkService for fetch-extract-store pipeline"
```

---

### Task 5: SidebarViewController — replace FeedsViewController

**Files:**
- Create: `LES/UI/SidebarViewController.swift`
- Delete: `LES/UI/FeedsViewController.swift`
- Modify: `LES/UI/MainWindowController.swift` (wire new sidebar)
- Modify: `LES/Keyboard/KeyCommandRouter.swift` (update references)

- [ ] **Step 1: Create SidebarViewController**

Create `LES/UI/SidebarViewController.swift`:

```swift
import Cocoa

enum SidebarSelection: Equatable {
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
        case .inbox: return "📥"
        case .readingList: return "📖"
        case .starred: return "⭐"
        case .today: return "📅"
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

// Wrapper types for NSOutlineView items (must be class/reference types for outline view identity)
private class SmartViewItem: NSObject {
    let smartView: SmartView
    var unreadCount: Int = 0
    init(_ smartView: SmartView) { self.smartView = smartView }
}

private class DividerItem: NSObject {}

private class FolderItem: NSObject {
    let name: String
    var feeds: [FeedRecord.RowViewModel]
    init(name: String, feeds: [FeedRecord.RowViewModel]) {
        self.name = name
        self.feeds = feeds
    }
}

private class FeedItem: NSObject {
    let feed: FeedRecord.RowViewModel
    init(_ feed: FeedRecord.RowViewModel) { self.feed = feed }
}

class SidebarViewController: NSViewController {
    var onSelectionChanged: ((SidebarSelection) -> Void)?
    private(set) var outlineView: NSOutlineView!
    private var scrollView: NSScrollView!

    private let accentColor = NSColor(calibratedRed: 0.545, green: 0.341, blue: 0.165, alpha: 1.0)

    // Data
    private var smartViewItems: [SmartViewItem] = SmartView.allCases.map { SmartViewItem($0) }
    private let divider = DividerItem()
    private var feedItems: [Any] = [] // FolderItem or FeedItem (no folder)

    var selectedFeedId: Int64? {
        guard let item = outlineView.item(atRow: outlineView.selectedRow) as? FeedItem else { return nil }
        return item.feed.id
    }

    var currentSelection: SidebarSelection? {
        let row = outlineView.selectedRow
        guard row >= 0 else { return nil }
        let item = outlineView.item(atRow: row)
        if let sv = item as? SmartViewItem { return .smartView(sv.smartView) }
        if let fi = item as? FeedItem { return .feed(fi.feed.id) }
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
        outlineView.selectionHighlightStyle = .sourceList

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
        do {
            let itemStore = ItemStore(db: DatabaseManager.shared.dbPool)
            let feedStore = FeedStore(db: DatabaseManager.shared.dbPool)

            // Update smart view counts
            smartViewItems[0].unreadCount = try itemStore.inboxUnreadCount()
            smartViewItems[1].unreadCount = try itemStore.readingListUnreadCount()
            smartViewItems[2].unreadCount = try itemStore.starredCount()
            smartViewItems[3].unreadCount = try itemStore.todayUnreadCount()

            // Build feed list
            let feeds = try feedStore.listFeeds()
            buildFeedItems(from: feeds)

            outlineView.reloadData()

            // Expand all folders
            for item in feedItems {
                if item is FolderItem {
                    outlineView.expandItem(item)
                }
            }
        } catch {}
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

        feedItems = []
        for feed in noFolder {
            feedItems.append(FeedItem(feed))
        }
        for folder in grouped.keys.sorted() {
            feedItems.append(FolderItem(name: folder, feeds: grouped[folder]!))
        }
    }

    // MARK: - Vim navigation

    func selectNext() {
        let row = outlineView.selectedRow
        var nextRow = row + 1
        // Skip divider
        while nextRow < outlineView.numberOfRows {
            if outlineView.item(atRow: nextRow) is DividerItem {
                nextRow += 1
            } else {
                break
            }
        }
        if nextRow < outlineView.numberOfRows {
            outlineView.selectRowIndexes(IndexSet(integer: nextRow), byExtendingSelection: false)
            outlineView.scrollRowToVisible(nextRow)
            notifySelection()
        }
    }

    func selectPrevious() {
        let row = outlineView.selectedRow
        var prevRow = row - 1
        // Skip divider
        while prevRow >= 0 {
            if outlineView.item(atRow: prevRow) is DividerItem {
                prevRow -= 1
            } else {
                break
            }
        }
        if prevRow >= 0 {
            outlineView.selectRowIndexes(IndexSet(integer: prevRow), byExtendingSelection: false)
            outlineView.scrollRowToVisible(prevRow)
            notifySelection()
        }
    }

    private func notifySelection() {
        guard let selection = currentSelection else { return }
        onSelectionChanged?(selection)
    }
}

// MARK: - NSOutlineViewDataSource

extension SidebarViewController: NSOutlineViewDataSource {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil {
            // Root: smart views + divider + feed items
            return smartViewItems.count + 1 + feedItems.count
        }
        if let folder = item as? FolderItem {
            return folder.feeds.count
        }
        return 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil {
            let smartCount = smartViewItems.count
            if index < smartCount {
                return smartViewItems[index]
            } else if index == smartCount {
                return divider
            } else {
                return feedItems[index - smartCount - 1]
            }
        }
        if let folder = item as? FolderItem {
            return FeedItem(folder.feeds[index])
        }
        return NSObject()
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        return item is FolderItem
    }
}

// MARK: - NSOutlineViewDelegate

extension SidebarViewController: NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if let sv = item as? SmartViewItem {
            let cellID = NSUserInterfaceItemIdentifier("SmartViewCell")
            let cell = outlineView.makeView(withIdentifier: cellID, owner: self) as? SidebarCellView
                ?? SidebarCellView(identifier: cellID, accentColor: accentColor)
            cell.configure(
                icon: sv.smartView.icon,
                title: sv.smartView.rawValue,
                count: sv.unreadCount,
                isBold: sv.unreadCount > 0
            )
            return cell
        }

        if item is DividerItem {
            let cellID = NSUserInterfaceItemIdentifier("DividerCell")
            let cell = outlineView.makeView(withIdentifier: cellID, owner: self) ?? makeDividerCell(identifier: cellID)
            return cell
        }

        if let folder = item as? FolderItem {
            let cellID = NSUserInterfaceItemIdentifier("FolderCell")
            let cell = outlineView.makeView(withIdentifier: cellID, owner: self) as? NSTableCellView
                ?? makeFolderCell(identifier: cellID)
            cell.textField?.stringValue = folder.name
            return cell
        }

        if let fi = item as? FeedItem {
            let cellID = NSUserInterfaceItemIdentifier("FeedCell")
            let cell = outlineView.makeView(withIdentifier: cellID, owner: self) as? SidebarCellView
                ?? SidebarCellView(identifier: cellID, accentColor: accentColor)
            cell.configure(
                icon: nil,
                title: fi.feed.title,
                count: fi.feed.unreadCount,
                isBold: fi.feed.unreadCount > 0
            )
            return cell
        }

        return nil
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        if item is DividerItem { return 25 }
        return 28
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        // Don't allow selecting divider or folder headers
        if item is DividerItem { return false }
        if item is FolderItem { return false }
        return true
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        notifySelection()
    }

    private func makeFolderCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let tf = NSTextField(labelWithString: "")
        tf.translatesAutoresizingMaskIntoConstraints = false
        tf.font = .systemFont(ofSize: 11, weight: .semibold)
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

    private func makeDividerCell(identifier: NSUserInterfaceItemIdentifier) -> NSView {
        let cell = NSView()
        cell.identifier = identifier
        let line = NSView()
        line.translatesAutoresizingMaskIntoConstraints = false
        line.wantsLayer = true
        line.layer?.backgroundColor = NSColor(calibratedWhite: 0.0, alpha: 0.06).cgColor
        cell.addSubview(line)
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 12),
            line.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -12),
            line.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            line.heightAnchor.constraint(equalToConstant: 1),
        ])
        return cell
    }
}

// MARK: - Sidebar cell with icon + title + count

private class SidebarCellView: NSTableCellView {
    private let iconLabel = NSTextField(labelWithString: "")
    private let titleField = NSTextField(labelWithString: "")
    private let countBadge = NSTextField(labelWithString: "")

    convenience init(identifier: NSUserInterfaceItemIdentifier, accentColor: NSColor) {
        self.init()
        self.identifier = identifier

        iconLabel.translatesAutoresizingMaskIntoConstraints = false
        iconLabel.font = .systemFont(ofSize: 13)
        addSubview(iconLabel)

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
            iconLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            iconLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconLabel.widthAnchor.constraint(equalToConstant: 20),

            titleField.leadingAnchor.constraint(equalTo: iconLabel.trailingAnchor, constant: 4),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleField.trailingAnchor.constraint(lessThanOrEqualTo: countBadge.leadingAnchor, constant: -6),

            countBadge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            countBadge.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    func configure(icon: String?, title: String, count: Int, isBold: Bool) {
        iconLabel.stringValue = icon ?? ""
        iconLabel.isHidden = icon == nil

        titleField.stringValue = title
        titleField.font = .systemFont(ofSize: 13, weight: isBold ? .medium : .regular)
        titleField.textColor = .labelColor

        // Adjust title leading when no icon
        if icon == nil {
            // Remove icon width from layout
            iconLabel.isHidden = true
        }

        if count > 0 {
            countBadge.stringValue = "\(count)"
            countBadge.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            countBadge.isHidden = false
        } else {
            countBadge.isHidden = true
        }
    }
}
```

- [ ] **Step 2: Delete FeedsViewController.swift**

```bash
rm LES/UI/FeedsViewController.swift
```

- [ ] **Step 3: Update MainWindowController**

In `LES/UI/MainWindowController.swift`:

Change `feedsVC` to `sidebarVC`:

```swift
var sidebarVC: SidebarViewController!
var itemsVC: ItemsViewController!
var readerVC: ReaderViewController!
```

In `setupSplitView()`, replace:

```swift
sidebarVC = SidebarViewController()
itemsVC = ItemsViewController()
readerVC = ReaderViewController()

let splitVC = NSSplitViewController()

let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarVC)
sidebarItem.minimumThickness = 180
sidebarItem.maximumThickness = 300
sidebarItem.canCollapse = true

let itemsItem = NSSplitViewItem(contentListWithViewController: itemsVC)
itemsItem.minimumThickness = 250
itemsItem.canCollapse = false

let readerItem = NSSplitViewItem(viewController: readerVC)
readerItem.minimumThickness = 300
readerItem.canCollapse = true

splitVC.addSplitViewItem(sidebarItem)
splitVC.addSplitViewItem(itemsItem)
splitVC.addSplitViewItem(readerItem)

window?.contentViewController = splitVC

sidebarVC.onSelectionChanged = { [weak self] selection in
    guard let self else { return }
    switch selection {
    case .smartView(let sv):
        self.itemsVC.showItems(forFilter: sv.filter)
    case .feed(let feedId):
        self.itemsVC.showItems(forFeedId: feedId)
    }
    self.readerVC.clear()
}

itemsVC.onItemSelected = { [weak self] itemId in
    self?.readerVC.showItem(itemId: itemId)
}
```

Update `refreshCurrentFeed`:

```swift
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
    Task {
        await RefreshScheduler.shared.refreshAllFeeds()
        await MainActor.run {
            self.sidebarVC?.reloadData()
            self.itemsVC?.reload()
        }
    }
}
```

Update `addFeed` — change `self?.feedsVC?.reloadFeeds()` to `self?.sidebarVC?.reloadData()`.

Update `importOPML` — change `self?.feedsVC?.reloadFeeds()` to `self?.sidebarVC?.reloadData()`.

Update focus methods:

```swift
func focusFeedsPane() {
    window?.makeFirstResponder(sidebarVC?.outlineView)
}
```

Add `addBookmark` action:

```swift
@objc func addBookmark(_ sender: Any?) {
    let alert = NSAlert()
    alert.messageText = "Add Bookmark"
    alert.informativeText = "Enter the article URL:"
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
                let service = BookmarkService()
                try await service.addBookmark(url: urlString, db: DatabaseManager.shared.dbPool)
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
```

- [ ] **Step 4: Update ItemsViewController — add showItems(forFilter:)**

In `LES/UI/ItemsViewController.swift`, add this method alongside the existing `showItems(forFeedId:)`:

```swift
func showItems(forFilter filter: ItemFilter) {
    currentFeedId = nil
    currentFilter = filter
    loadItems(append: false)
}
```

- [ ] **Step 5: Update ItemCellView to show bookmark badge**

In `LES/UI/ItemsViewController.swift`, update the `configure` call in `tableView(_:viewFor:row:)`:

```swift
cell.configure(
    title: item.title,
    date: item.publishedAt.map { formatDate($0) } ?? "",
    author: item.author,
    isRead: item.isRead,
    isStarred: item.isStarred,
    isBookmark: item.isBookmark
)
```

Update `ItemCellView.configure` to accept `isBookmark` and show a small indicator:

In the `ItemCellView` class, add a `bookmarkLabel` field:

```swift
private let bookmarkLabel = NSTextField(labelWithString: "")
```

In the `convenience init`, add setup for bookmarkLabel before the constraints:

```swift
bookmarkLabel.translatesAutoresizingMaskIntoConstraints = false
bookmarkLabel.font = .systemFont(ofSize: 10)
bookmarkLabel.textColor = NSColor(calibratedRed: 0.545, green: 0.341, blue: 0.165, alpha: 0.7)
addSubview(bookmarkLabel)
```

Add bookmark label constraint — place it after the star label on the bottom row:

```swift
bookmarkLabel.firstBaselineAnchor.constraint(equalTo: starLabel.firstBaselineAnchor),
bookmarkLabel.leadingAnchor.constraint(equalTo: starLabel.trailingAnchor, constant: 2),
```

And change the author constraint to anchor to bookmarkLabel instead of starLabel:

```swift
authorField.leadingAnchor.constraint(equalTo: bookmarkLabel.trailingAnchor, constant: 2),
```

Update `configure` signature and add:

```swift
func configure(title: String, date: String, author: String?, isRead: Bool, isStarred: Bool, isBookmark: Bool) {
    // ... existing code ...
    bookmarkLabel.stringValue = isBookmark ? "↗" : ""
}
```

- [ ] **Step 6: Update KeyCommandRouter**

In `LES/Keyboard/KeyCommandRouter.swift`:

Replace all `wc.itemsVC` feed-nav calls. Add `b` key binding. Update pane references:

In the `performAction` method, change:
- `wc.feedsVC?.selectedFeedId` references don't exist anymore — the router calls `wc` methods which internally use `sidebarVC`

Add `addBookmark` case to the VimAction enum:
```swift
case addBookmark
```

Add in the switch in `handleVimKey`:
```swift
case "b":
    performAction(.addBookmark)
    return true
```

Add in the switch in `performAction`:
```swift
case .addBookmark:
    wc.addBookmark(nil)
```

- [ ] **Step 7: Update AppDelegate menu**

In `LES/AppDelegate.swift`, in `buildMainMenu()`, add after the "Add Feed…" menu item:

```swift
fileMenu.addItem(withTitle: "Add Bookmark…", action: #selector(MainWindowController.addBookmark(_:)), keyEquivalent: "b")
```

- [ ] **Step 8: Build and verify**

Run: `swift build`
Expected: Compiles with no errors.

- [ ] **Step 9: Commit**

```bash
git add -A
git commit -m "feat: replace FeedsViewController with activity-based SidebarViewController

Adds smart views (Inbox, Reading List, Starred, Today) above feeds.
Adds bookmark support with 'b' key and Cmd+B menu item."
```

---

### Task 6: Image support in ReaderRenderer

**Files:**
- Modify: `LES/Rendering/ReaderRenderer.swift` (enable images with styling)
- Create: `LES/Rendering/ImageCache.swift` (disk cache for downloaded images)
- Modify: `LES/Stores/ReaderCacheStore.swift` (bump version)

- [ ] **Step 1: Create ImageCache**

Create `LES/Rendering/ImageCache.swift`:

```swift
import Foundation
import Cocoa
import CryptoKit

actor ImageCache {
    static let shared = ImageCache()

    private let cacheDir: URL

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        cacheDir = appSupport.appendingPathComponent("LES/images", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    func image(for url: URL) async -> NSImage? {
        // Check disk cache
        let key = cacheKey(for: url)
        let filePath = cacheDir.appendingPathComponent(key)

        if let data = try? Data(contentsOf: filePath),
           let image = NSImage(data: data) {
            return image
        }

        // Download
        do {
            var request = URLRequest(url: url)
            request.setValue("LES/1.0", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                return nil
            }

            guard let image = NSImage(data: data) else { return nil }

            // Cache to disk
            try? data.write(to: filePath)

            return image
        } catch {
            return nil
        }
    }

    private func cacheKey(for url: URL) -> String {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
```

- [ ] **Step 2: Update ReaderRenderer — enable images with rounded styling**

In `LES/Rendering/ReaderRenderer.swift`, replace the `img { display: none; }` CSS rule with:

```css
img {
    max-width: 100%;
    height: auto;
    border-radius: 8px;
    margin: 0.8em 0;
    display: block;
}
figure {
    margin: 1.2em 0;
    padding: 0;
}
figcaption {
    font-size: 13px;
    color: #888;
    margin-top: 6px;
    text-align: center;
}
```

- [ ] **Step 3: Bump reader cache version**

In `LES/Stores/ReaderCacheStore.swift`, change:

```swift
static let currentVersion = 3
```

- [ ] **Step 4: Build and verify**

Run: `swift build`
Expected: Compiles with no errors.

- [ ] **Step 5: Commit**

```bash
git add LES/Rendering/ImageCache.swift LES/Rendering/ReaderRenderer.swift LES/Stores/ReaderCacheStore.swift
git commit -m "feat: enable inline images with disk cache and placeholder support"
```

---

### Task 7: Integration wiring and final build verification

**Files:**
- Verify all files compile together
- Test the full flow manually

- [ ] **Step 1: Clean build**

```bash
swift package clean && swift build
```

Expected: Compiles with no errors.

- [ ] **Step 2: Run the app and test**

```bash
swift run
```

Test manually:
1. Sidebar shows Inbox, Reading List, Starred, Today above the divider
2. Feeds appear below the divider
3. Selecting Inbox shows all unread items
4. Press `b` — Add Bookmark sheet appears
5. Paste a URL (e.g., a blog post), click Add
6. Bookmark appears in Inbox with ↗ indicator
7. Select the bookmark — reader shows extracted content
8. Bookmark persists in Reading List after being read
9. Images render inline in articles (both RSS and bookmarks)
10. `j`/`k`/`h`/`l` vim navigation works across sidebar

- [ ] **Step 3: Commit any fixes**

If any fixes were needed during testing, commit them.

- [ ] **Step 4: Final commit**

```bash
git add -A
git commit -m "feat: sidebar redesign + read-it-later bookmarks + inline images

- Activity-based sidebar with Inbox, Reading List, Starred, Today
- Read-it-later bookmarks with Readability content extraction
- Inline image support with async loading and disk cache
- 'b' key and Cmd+B to add bookmarks"
```
