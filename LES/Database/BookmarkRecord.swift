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
