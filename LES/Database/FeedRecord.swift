import Foundation
import GRDB

struct FeedRecord: Codable, FetchableRecord, PersistableRecord, Identifiable {
    static let databaseTableName = "feeds"

    var id: Int64?
    var title: String?
    var url: String
    var siteURL: String?
    var folder: String?
    var lastFetchedAt: TimeInterval?
    var etag: String?
    var lastModified: String?
    var lastError: String?
    var errorCount: Int = 0
    var isMuted: Bool = false
    var createdAt: TimeInterval
    var updatedAt: TimeInterval

    // GRDB auto-increment support
    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    /// Lightweight view model for the feeds list — no heavy fields
    struct RowViewModel {
        let id: Int64
        let title: String
        let folder: String?
        let siteHost: String?
        let unreadCount: Int
        let isMuted: Bool
        let hasError: Bool
    }
}

extension FeedRecord {
    static let items = hasMany(ItemRecord.self)

    var items: QueryInterfaceRequest<ItemRecord> {
        request(for: FeedRecord.items)
    }
}

// Boolean column coding for isMuted
extension FeedRecord: MutablePersistableRecord {}
