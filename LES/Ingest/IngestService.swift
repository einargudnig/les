import Foundation
import GRDB

struct IngestService {
    let db: DatabasePool
    let maxItemsPerFeed: Int = 2000

    func ingest(feedId: Int64, parsed: ParsedFeed) throws {
        try db.write { db in
            for parsedItem in parsed.items {
                let stableId = ItemRecord.stableID(
                    feedId: feedId,
                    externalId: parsedItem.externalId,
                    url: parsedItem.link,
                    title: parsedItem.title,
                    publishedAt: parsedItem.publishedAt
                )

                // Check if item already exists
                if let existing = try ItemRecord.fetchOne(db, key: stableId) {
                    // Update only if new data is non-empty and different
                    var changed = false
                    var updated = existing

                    if let title = parsedItem.title, !title.isEmpty, title != existing.title {
                        updated.title = title
                        changed = true
                    }
                    if let summary = parsedItem.summaryHTML, !summary.isEmpty,
                       (existing.summaryHTML == nil || existing.summaryHTML!.isEmpty) {
                        updated.summaryHTML = summary
                        changed = true
                    }
                    if let content = parsedItem.contentHTML, !content.isEmpty,
                       (existing.contentHTML == nil || existing.contentHTML!.isEmpty) {
                        updated.contentHTML = content
                        changed = true
                    }
                    if let author = parsedItem.author, !author.isEmpty, existing.author == nil {
                        updated.author = author
                        changed = true
                    }

                    if changed {
                        updated.updatedAt = Date().timeIntervalSince1970
                        try updated.update(db)
                    }
                } else {
                    // Insert new item — never set readAt or starredAt
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
                    try item.insert(db)
                }
            }

            // Enforce max items per feed: delete oldest read items first
            let totalCount = try ItemRecord
                .filter(Column("feedId") == feedId)
                .fetchCount(db)

            if totalCount > maxItemsPerFeed {
                let excess = totalCount - maxItemsPerFeed
                // Delete oldest read items first, then oldest unread if needed
                try db.execute(sql: """
                    DELETE FROM items WHERE id IN (
                        SELECT id FROM items
                        WHERE feedId = ? AND readAt IS NOT NULL AND starredAt IS NULL
                        ORDER BY publishedAt ASC
                        LIMIT ?
                    )
                    """, arguments: [feedId, excess])
            }
        }
    }
}
