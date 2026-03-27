# Sidebar Redesign + Read-It-Later

## Overview

Transform LES from an RSS-only reader into a unified reading app with an activity-based sidebar and read-it-later bookmarking. The reader experience stays consistent across RSS and bookmarked content.

## Sidebar Structure

The left pane changes from a feeds-only outline to an activity-based sidebar with two zones separated by a thin divider.

### Top Zone — Smart Views

Fixed items, not user-configurable:

- **Inbox** — All unread items across RSS feeds and bookmarks. Bookmarks display a subtle badge/indicator to distinguish them from feed items. Selecting Inbox populates the items list with all unread, sorted by date descending.
- **Reading List** — All bookmarked articles regardless of read state. This is a persistent collection: items remain here until the user explicitly removes them. Reading an article marks it read but does not remove it from Reading List.
- **Starred** — All starred items (RSS and bookmarks).
- **Today** — All items published or saved today.

Each smart view shows an unread count badge (warm brown, same style as current feed counts). Smart views with zero unread show no badge.

### Bottom Zone — Feeds

Below the thin divider, the existing feed structure:

- Collapsible folders containing individual feeds
- Unread counts per feed
- Same behavior as current: selecting a feed filters the items list to that feed

### Divider

A 1px line with subtle opacity (same as the current reader separator style), with 12px vertical margin above and below.

### Vim Navigation

`j`/`k` navigate between all sidebar items (smart views and feeds). `h`/`l` move between panes as before. Smart views and feeds are in one continuous list for navigation purposes.

## Bookmarks Data Model

### New Table: `bookmarks`

```sql
CREATE TABLE bookmarks (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    url TEXT NOT NULL UNIQUE,
    siteName TEXT,
    extractedAt REAL,
    createdAt REAL NOT NULL,
    updatedAt REAL NOT NULL
);
```

Purpose: Stores source metadata for bookmarked articles. The extracted content itself lives in the `items` table.

### Changes to `items` Table

Make `feedId` nullable (currently `NOT NULL`) and add `bookmarkId`:

```sql
-- feedId must become nullable for bookmark items
-- SQLite doesn't support ALTER COLUMN, so this is handled by
-- creating the column as nullable in the migration (GRDB migration
-- recreates the table with the new schema)

ALTER TABLE items ADD COLUMN bookmarkId INTEGER REFERENCES bookmarks(id) ON DELETE CASCADE;
```

An item belongs to either a feed (`feedId` set, `bookmarkId` NULL) or a bookmark (`bookmarkId` set, `feedId` NULL). This keeps all content in one table so smart view queries (Inbox, Starred, Today) work without UNIONs.

**Constraint**: Exactly one of `feedId` or `bookmarkId` must be non-NULL. Enforced at the application layer (not a SQL CHECK, to keep migrations simple).

Add an index:

```sql
CREATE INDEX idx_items_bookmarkId ON items(bookmarkId);
```

### Item Type Detection

- `feedId != NULL` → RSS item
- `bookmarkId != NULL` → Bookmarked article
- Used by the UI to show bookmark indicator badge in the items list

## Content Extraction Pipeline

### BookmarkService

When the user bookmarks a URL:

1. **Insert bookmark record** — Store URL and `createdAt` in `bookmarks` table immediately
2. **Fetch HTML** — `URLSession` GET request with standard browser User-Agent
3. **Extract content** — Run Swift Readability to extract:
   - Title
   - Author
   - Main content HTML
   - Lead image URL (if present)
4. **Create item** — Insert into `items` table with:
   - `bookmarkId` set to the bookmark's ID
   - `feedId` = NULL
   - `id` = SHA-256 of `"bookmark:" + url`
   - `title`, `author`, `contentHTML` from extraction
   - `publishedAt` = current time (or extracted publish date if available)
   - `readAt` = NULL (unread, appears in Inbox)
5. **Update bookmark** — Set `extractedAt`, `siteName`

### Error Handling

If extraction fails (network error, unparseable page):
- Store the bookmark with title = URL
- Set `contentHTML` to a simple message: "Could not extract article content." with a link to open in browser
- User can retry extraction later

### Readability Implementation

Implement a custom content extractor in Swift (no external dependency) based on the Readability algorithm:

1. Parse HTML into a DOM tree using `XMLDocument` or a lightweight HTML parser
2. Score nodes by text density: prefer `<p>` blocks with high text-to-tag ratio
3. Find the top-scoring content node (usually `<article>`, `<main>`, or highest-scoring `<div>`)
4. Strip non-content elements: `<nav>`, `<footer>`, `<aside>`, `<header>`, ad-related classes, scripts, styles
5. Preserve: `<p>`, `<h1>`–`<h6>`, `<ul>`/`<ol>`/`<li>`, `<blockquote>`, `<pre>`/`<code>`, `<img>`, `<a>`, `<em>`/`<strong>`, `<figure>`/`<figcaption>`
6. Extract metadata: title (from `<title>`, `og:title`, or `<h1>`), author (from `<meta name="author">` or byline patterns), publish date

This keeps the app dependency-light and gives us full control over extraction behavior.

## Image Handling

### Renderer Changes

Remove `img { display: none }` from `ReaderRenderer`. Images render inline where they appear in the article HTML.

### Async Loading with Placeholders

Images load asynchronously to keep the reader fast:

1. During HTML → `NSAttributedString` conversion, replace `<img>` tags with `NSTextAttachment` placeholders
2. Placeholders display as light gray rounded rectangles at estimated dimensions (use `width`/`height` attributes from HTML if available, otherwise default to content-width × 200px)
3. Kick off async download for each image URL
4. On download completion, replace the placeholder attachment with the actual image
5. Cache downloaded images to disk (file cache in Application Support, keyed by URL SHA-256)

### Image Cache

- Location: `~/Library/Application Support/LES/images/`
- Key: SHA-256 of image URL → filename
- No size limit for MVP; add LRU eviction later if needed
- Cache is separate from `readerCache` table (images are shared across items)

### Scope

- Inline images only (no lightbox or zoom for MVP)
- GIF support: display first frame as static image
- SVG: skip (display nothing)
- Max rendered width: constrained to text container width

## Store Changes

### FeedStore

No changes. Continues to manage feeds only.

### ItemStore

Update `listItems()` to support the new smart views:

- **Inbox**: `WHERE readAt IS NULL` (both feed and bookmark items)
- **Reading List**: `WHERE bookmarkId IS NOT NULL`
- **Starred**: `WHERE starredAt IS NOT NULL` (unchanged)
- **Today**: `WHERE publishedAt >= ?` (unchanged)
- **Feed filter**: `WHERE feedId = ?` (unchanged)

Add `isBookmark` to `ItemRecord.RowViewModel`:

```swift
struct RowViewModel {
    let id: String
    let title: String
    let author: String?
    let publishedAt: TimeInterval?
    let isRead: Bool
    let isStarred: Bool
    let isBookmark: Bool  // NEW
}
```

### New: BookmarkStore

```swift
struct BookmarkStore {
    func insertBookmark(url: String) throws -> BookmarkRecord
    func deleteBookmark(id: Int64) throws
    func bookmarkByURL(_ url: String) throws -> BookmarkRecord?
}
```

## UI Changes

### FeedsViewController → SidebarViewController

Rename and restructure to handle both smart views and feeds:

- Data source becomes a three-part list:
  1. Smart view items (Inbox, Reading List, Starred, Today) — static, not from DB
  2. Thin divider row
  3. Feed folders and feeds (from DB, same as current)

- Smart view selection calls `ItemsViewController.showItems()` with a new filter enum case
- Feed selection works as before

### ItemsViewController

- The bookmark badge: when `isBookmark` is true, show a small bookmark icon (or "↗" indicator) next to the title
- No other changes needed — the items list already works with filters

### Add Bookmark Flow

- New keyboard shortcut: `b` in vim mode → opens "Add Bookmark" sheet (same pattern as Cmd+N for feeds)
- Menu item: File → Add Bookmark… (Cmd+B)
- Sheet has a URL text field, user pastes URL, presses Add
- Extraction happens async; item appears in Inbox when done

## Migration

### Database Migration v2

Single migration that:
1. Creates `bookmarks` table
2. Adds `bookmarkId` column to `items` (nullable, no data migration needed)
3. Creates `idx_items_bookmarkId` index

Existing data is unaffected — all current items have `feedId` set and `bookmarkId` NULL.

## What This Does NOT Include

- Browser/Share Extension (future)
- Raycast extension (future)
- Tags or labels
- Archive view
- Podcast support
- Full-text search (existing LIKE search continues to work)
- Image zoom/lightbox
- Offline mode beyond what's already cached
