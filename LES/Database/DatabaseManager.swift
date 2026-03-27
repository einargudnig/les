import Foundation
import GRDB

final class DatabaseManager {
    static let shared = DatabaseManager()

    private(set) var dbPool: DatabasePool!

    private init() {}

    func setup(at url: URL? = nil) throws {
        let dbURL: URL
        if let url {
            dbURL = url
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let appDir = appSupport.appendingPathComponent("LES", isDirectory: true)
            try FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
            dbURL = appDir.appendingPathComponent("les.sqlite")
        }

        var config = Configuration()
        config.foreignKeysEnabled = true
        config.prepareDatabase { db in
            // WAL mode for concurrent reads
            try db.execute(sql: "PRAGMA journal_mode = WAL")
        }

        dbPool = try DatabasePool(path: dbURL.path, configuration: config)
        try migrator.migrate(dbPool)
    }

    /// For in-memory testing
    func setupInMemory() throws {
        var config = Configuration()
        config.foreignKeysEnabled = true
        dbPool = try DatabasePool(path: ":memory:", configuration: config)
        try migrator.migrate(dbPool)
    }

    private var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_create_feeds_items") { db in
            try db.create(table: "feeds") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("title", .text)
                t.column("url", .text).notNull().unique()
                t.column("siteURL", .text)
                t.column("folder", .text)
                t.column("lastFetchedAt", .double)
                t.column("etag", .text)
                t.column("lastModified", .text)
                t.column("lastError", .text)
                t.column("errorCount", .integer).notNull().defaults(to: 0)
                t.column("isMuted", .integer).notNull().defaults(to: 0)
                t.column("createdAt", .double).notNull()
                t.column("updatedAt", .double).notNull()
            }

            try db.create(table: "items") { t in
                t.primaryKey("id", .text)
                t.column("feedId", .integer).notNull()
                    .references("feeds", onDelete: .cascade)
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

            try db.create(
                index: "idx_items_feed_published",
                on: "items",
                columns: ["feedId", "publishedAt"]
            )
            try db.create(
                index: "idx_items_readAt",
                on: "items",
                columns: ["readAt"]
            )
            try db.create(
                index: "idx_items_starredAt",
                on: "items",
                columns: ["starredAt"]
            )

            try db.create(table: "readerCache") { t in
                t.primaryKey("itemId", .text)
                    .references("items", onDelete: .cascade)
                t.column("renderedData", .blob)
                t.column("computedAt", .double).notNull()
                t.column("version", .integer).notNull()
            }
        }

        migrator.registerMigration("v2_bookmarks") { db in
            try db.create(table: "bookmarks") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("url", .text).notNull().unique()
                t.column("siteName", .text)
                t.column("extractedAt", .double)
                t.column("createdAt", .double).notNull()
                t.column("updatedAt", .double).notNull()
            }

            // Recreate items table with nullable feedId and new bookmarkId column
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

        return migrator
    }
}
