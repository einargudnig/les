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
