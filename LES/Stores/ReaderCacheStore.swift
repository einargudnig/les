import Foundation
import GRDB

struct ReaderCacheEntry: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "readerCache"

    var itemId: String
    var renderedData: Data?
    var computedAt: TimeInterval
    var version: Int

    static let currentVersion = 3
}

struct ReaderCacheStore {
    let db: DatabasePool

    func cached(itemId: String) throws -> ReaderCacheEntry? {
        try db.read { db in
            try ReaderCacheEntry
                .filter(Column("itemId") == itemId && Column("version") == ReaderCacheEntry.currentVersion)
                .fetchOne(db)
        }
    }

    func store(itemId: String, renderedData: Data) throws {
        try db.write { db in
            let entry = ReaderCacheEntry(
                itemId: itemId,
                renderedData: renderedData,
                computedAt: Date().timeIntervalSince1970,
                version: ReaderCacheEntry.currentVersion
            )
            try entry.save(db)
        }
    }

    func evictOldEntries(keepCount: Int = 500) throws {
        try db.write { db in
            let totalCount = try ReaderCacheEntry.fetchCount(db)
            guard totalCount > keepCount else { return }
            let toDelete = totalCount - keepCount
            try db.execute(
                sql: "DELETE FROM readerCache WHERE itemId IN (SELECT itemId FROM readerCache ORDER BY computedAt ASC LIMIT ?)",
                arguments: [toDelete]
            )
        }
    }

    func invalidateAll() throws {
        try db.write { db in
            try db.execute(sql: "DELETE FROM readerCache")
        }
    }
}
