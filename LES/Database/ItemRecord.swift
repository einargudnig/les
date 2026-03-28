import Foundation
import GRDB
import CryptoKit

struct ItemRecord: Codable, FetchableRecord, PersistableRecord, Identifiable {
    static let databaseTableName = "items"

    var id: String
    var feedId: Int64?
    var bookmarkId: Int64?
    var title: String?
    var author: String?
    var url: String?
    var externalId: String?
    var publishedAt: TimeInterval?
    var updatedAt: TimeInterval?
    var summaryHTML: String?
    var contentHTML: String?
    var readAt: TimeInterval?
    var starredAt: TimeInterval?

    var isRead: Bool { readAt != nil }
    var isStarred: Bool { starredAt != nil }
    var isBookmark: Bool { bookmarkId != nil }

    /// Lightweight view model for the items list
    struct RowViewModel {
        let id: String
        let title: String
        let author: String?
        let url: String?
        let publishedAt: TimeInterval?
        let isRead: Bool
        let isStarred: Bool
        let isBookmark: Bool
    }

    /// Full content for the reader pane
    struct Content {
        let id: String
        let title: String?
        let author: String?
        let url: String?
        let publishedAt: TimeInterval?
        let summaryHTML: String?
        let contentHTML: String?
        let isBookmark: Bool
    }
}

extension ItemRecord {
    static let feed = belongsTo(FeedRecord.self)

    /// Compute a stable item ID for bookmarks
    static func bookmarkStableID(url: String) -> String {
        let input = "bookmark:\(url)"
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Compute a stable, deduplicated item ID
    static func stableID(feedId: Int64, externalId: String?, url: String?, title: String?, publishedAt: TimeInterval?) -> String {
        let input: String
        if let externalId, !externalId.isEmpty {
            input = "\(feedId):\(externalId)"
        } else if let url, !url.isEmpty {
            input = "\(feedId):\(url)"
        } else {
            let t = title ?? ""
            let p = publishedAt.map { String($0) } ?? ""
            input = "\(feedId):\(t):\(p)"
        }
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
