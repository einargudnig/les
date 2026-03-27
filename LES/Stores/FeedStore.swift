import Foundation
import GRDB

struct FeedStore {
    let db: DatabasePool

    func listFeeds() throws -> [FeedRecord.RowViewModel] {
        try db.read { db in
            let feeds = try FeedRecord.fetchAll(db)
            return try feeds.map { feed in
                let unreadCount = try ItemRecord
                    .filter(Column("feedId") == feed.id && Column("readAt") == nil)
                    .fetchCount(db)
                return FeedRecord.RowViewModel(
                    id: feed.id!,
                    title: feed.title ?? feed.url,
                    folder: feed.folder,
                    unreadCount: unreadCount,
                    isMuted: feed.isMuted
                )
            }
        }
    }

    func feed(id: Int64) throws -> FeedRecord? {
        try db.read { db in
            try FeedRecord.fetchOne(db, key: id)
        }
    }

    func feedByURL(_ url: String) throws -> FeedRecord? {
        try db.read { db in
            try FeedRecord.filter(Column("url") == url).fetchOne(db)
        }
    }

    @discardableResult
    func insertFeed(url: String, title: String? = nil, folder: String? = nil) throws -> FeedRecord {
        try db.write { db in
            let now = Date().timeIntervalSince1970
            var feed = FeedRecord(
                url: url,
                folder: folder,
                createdAt: now,
                updatedAt: now
            )
            feed.title = title
            try feed.insert(db)
            return feed
        }
    }

    func deleteFeed(id: Int64) throws {
        try db.write { db in
            _ = try FeedRecord.deleteOne(db, key: id)
        }
    }

    func updateFeedMeta(
        id: Int64,
        title: String?,
        siteURL: String?,
        etag: String?,
        lastModified: String?,
        lastFetchedAt: TimeInterval
    ) throws {
        try db.write { db in
            if var feed = try FeedRecord.fetchOne(db, key: id) {
                if let title, !title.isEmpty { feed.title = title }
                if let siteURL { feed.siteURL = siteURL }
                feed.etag = etag
                feed.lastModified = lastModified
                feed.lastFetchedAt = lastFetchedAt
                feed.lastError = nil
                feed.errorCount = 0
                feed.updatedAt = Date().timeIntervalSince1970
                try feed.update(db)
            }
        }
    }

    func recordFeedError(id: Int64, error: String) throws {
        try db.write { db in
            if var feed = try FeedRecord.fetchOne(db, key: id) {
                feed.lastError = error
                feed.errorCount += 1
                feed.updatedAt = Date().timeIntervalSince1970
                try feed.update(db)
            }
        }
    }

    func allFeedsForRefresh() throws -> [FeedRecord] {
        try db.read { db in
            try FeedRecord
                .filter(Column("isMuted") == false)
                .fetchAll(db)
        }
    }

    func folders() throws -> [String] {
        try db.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT DISTINCT folder FROM feeds WHERE folder IS NOT NULL ORDER BY folder")
            return rows.compactMap { $0["folder"] as String? }
        }
    }
}
