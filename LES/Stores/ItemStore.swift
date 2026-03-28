import Foundation
import GRDB

enum ItemFilter {
    case all
    case unread      // Inbox
    case readingList // bookmarkId IS NOT NULL
    case starred
    case today
    case lastSevenDays
}

struct ItemStore {
    let db: DatabasePool

    func listItems(
        feedId: Int64? = nil,
        filter: ItemFilter = .all,
        search: String? = nil,
        beforePublishedAt: TimeInterval? = nil,
        limit: Int = 200
    ) throws -> [ItemRecord.RowViewModel] {
        try db.read { db in
            // Use direct SQL for lightweight fetch — avoids loading HTML content
            let sql = buildListSQL(feedId: feedId, filter: filter, search: search, beforePublishedAt: beforePublishedAt, limit: limit)
            let directRows = try Row.fetchAll(db, sql: sql.sql, arguments: sql.arguments)

            return directRows.map { row in
                ItemRecord.RowViewModel(
                    id: row["id"],
                    title: row["title"] ?? "Untitled",
                    author: row["author"],
                    url: row["url"],
                    publishedAt: row["publishedAt"],
                    isRead: row["readAt"] != nil,
                    isStarred: row["starredAt"] != nil,
                    isBookmark: (row["bookmarkId"] as Int64?) != nil
                )
            }
        }
    }

    private func buildListSQL(
        feedId: Int64?,
        filter: ItemFilter,
        search: String?,
        beforePublishedAt: TimeInterval?,
        limit: Int
    ) -> (sql: String, arguments: StatementArguments) {
        var conditions: [String] = []
        var args: [DatabaseValueConvertible?] = []

        if let feedId {
            conditions.append("feedId = ?")
            args.append(feedId)
        }

        let now = Date().timeIntervalSince1970
        switch filter {
        case .all: break
        case .unread:
            conditions.append("readAt IS NULL")
        case .readingList:
            conditions.append("bookmarkId IS NOT NULL")
        case .starred:
            conditions.append("starredAt IS NOT NULL")
        case .today:
            conditions.append("publishedAt >= ?")
            args.append(now - 86400)
        case .lastSevenDays:
            conditions.append("publishedAt >= ?")
            args.append(now - 86400 * 7)
        }

        if let search, !search.isEmpty {
            conditions.append("(title LIKE ? OR author LIKE ?)")
            let pattern = "%\(search)%"
            args.append(pattern)
            args.append(pattern)
        }

        if let cursor = beforePublishedAt {
            conditions.append("publishedAt < ?")
            args.append(cursor)
        }

        var sql = "SELECT id, title, author, url, publishedAt, readAt, starredAt, bookmarkId FROM items"
        if !conditions.isEmpty {
            sql += " WHERE " + conditions.joined(separator: " AND ")
        }
        sql += " ORDER BY publishedAt DESC LIMIT ?"
        args.append(limit)

        return (sql, StatementArguments(args)!)
    }

    func loadItemContent(id: String) throws -> ItemRecord.Content? {
        try db.read { db in
            guard let item = try ItemRecord.fetchOne(db, key: id) else { return nil }
            return ItemRecord.Content(
                id: item.id,
                title: item.title,
                author: item.author,
                url: item.url,
                publishedAt: item.publishedAt,
                summaryHTML: item.summaryHTML,
                contentHTML: item.contentHTML,
                isBookmark: item.isBookmark
            )
        }
    }

    func markRead(id: String) throws {
        try db.write { db in
            try db.execute(
                sql: "UPDATE items SET readAt = ? WHERE id = ? AND readAt IS NULL",
                arguments: [Date().timeIntervalSince1970, id]
            )
        }
    }

    func markUnread(id: String) throws {
        try db.write { db in
            try db.execute(sql: "UPDATE items SET readAt = NULL WHERE id = ?", arguments: [id])
        }
    }

    func toggleRead(id: String) throws {
        try db.write { db in
            let row = try Row.fetchOne(db, sql: "SELECT readAt FROM items WHERE id = ?", arguments: [id])
            if row?["readAt"] != nil {
                try db.execute(sql: "UPDATE items SET readAt = NULL WHERE id = ?", arguments: [id])
            } else {
                try db.execute(sql: "UPDATE items SET readAt = ? WHERE id = ?", arguments: [Date().timeIntervalSince1970, id])
            }
        }
    }

    func toggleStar(id: String) throws {
        try db.write { db in
            let row = try Row.fetchOne(db, sql: "SELECT starredAt FROM items WHERE id = ?", arguments: [id])
            if row?["starredAt"] != nil {
                try db.execute(sql: "UPDATE items SET starredAt = NULL WHERE id = ?", arguments: [id])
            } else {
                try db.execute(sql: "UPDATE items SET starredAt = ? WHERE id = ?", arguments: [Date().timeIntervalSince1970, id])
            }
        }
    }

    func markAllRead(feedId: Int64) throws {
        try db.write { db in
            try db.execute(
                sql: "UPDATE items SET readAt = ? WHERE feedId = ? AND readAt IS NULL",
                arguments: [Date().timeIntervalSince1970, feedId]
            )
        }
    }

    func unreadCount(feedId: Int64? = nil) throws -> Int {
        try db.read { db in
            var sql = "SELECT COUNT(*) FROM items WHERE readAt IS NULL"
            var args: [DatabaseValueConvertible] = []
            if let feedId {
                sql += " AND feedId = ?"
                args.append(feedId)
            }
            return try Int.fetchOne(db, sql: sql, arguments: StatementArguments(args)) ?? 0
        }
    }

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
}
