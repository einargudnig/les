import Foundation
import GRDB
import CryptoKit

actor BookmarkService {
    private let extractor = ReadabilityExtractor()

    func addBookmark(url: String, db: DatabasePool) async throws {
        // Check if item already exists for this URL
        let stableId = ItemRecord.bookmarkStableID(url: url)
        let existingItem = try await db.read { db in
            try ItemRecord.fetchOne(db, key: stableId)
        }
        if existingItem != nil { return }

        // Reuse existing bookmark record or create new one
        let bookmarkId: Int64 = try await db.write { db in
            if let existing = try BookmarkRecord.filter(Column("url") == url).fetchOne(db) {
                return existing.id!
            } else {
                let now = Date().timeIntervalSince1970
                var bookmark = BookmarkRecord(url: url, createdAt: now, updatedAt: now)
                try bookmark.insert(db)
                return db.lastInsertedRowID
            }
        }

        // Fetch and extract
        let extracted: ExtractedArticle
        do {
            extracted = try await fetchAndExtract(urlString: url)
        } catch {
            // Extraction failed — create fallback item
            let errorHTML = """
                <p>Could not extract article content.</p>
                <p><a href="\(url)">Open in browser</a></p>
            """
            let item = ItemRecord(
                id: stableId,
                feedId: nil,
                bookmarkId: bookmarkId,
                title: url,
                url: url,
                publishedAt: Date().timeIntervalSince1970,
                updatedAt: Date().timeIntervalSince1970,
                contentHTML: errorHTML
            )
            try? await db.write { db in try item.insert(db) }
            return
        }

        // Create item from extraction
        let item = ItemRecord(
            id: stableId,
            feedId: nil,
            bookmarkId: bookmarkId,
            title: extracted.title ?? url,
            author: extracted.author,
            url: url,
            publishedAt: extracted.publishedAt ?? Date().timeIntervalSince1970,
            updatedAt: Date().timeIntervalSince1970,
            contentHTML: extracted.contentHTML ?? Self.fallbackHTML(url: url)
        )

        try await db.write { db in try item.insert(db) }

        try await db.write { db in
            try db.execute(
                sql: "UPDATE bookmarks SET extractedAt = ?, siteName = ?, updatedAt = ? WHERE id = ?",
                arguments: [Date().timeIntervalSince1970, extracted.siteName, Date().timeIntervalSince1970, bookmarkId]
            )
        }
    }

    private static func fallbackHTML(url: String) -> String {
        let domain = URL(string: url)?.host ?? url
        return """
        <p style="margin-top: 1em;">Saved from <strong>\(domain)</strong></p>
        <p><a href="\(url)">\(url)</a></p>
        <p style="color: #888; margin-top: 2em; font-size: 14px;">
            Content could not be extracted from this page.
            Click the link above to read it in your browser.
        </p>
        """
    }

    private func fetchAndExtract(urlString: String) async throws -> ExtractedArticle {
        guard let url = URL(string: urlString) else {
            throw BookmarkError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        request.setValue("text/html", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw BookmarkError.fetchFailed
        }

        let encoding = httpResponse.textEncodingName
            .flatMap { CFStringConvertEncodingToNSStringEncoding(CFStringConvertIANACharSetNameToEncoding($0 as CFString)) }
            .flatMap { String.Encoding(rawValue: $0) }
            ?? .utf8

        guard let html = String(data: data, encoding: encoding) ?? String(data: data, encoding: .utf8) else {
            throw BookmarkError.decodeFailed
        }

        return extractor.extract(html: html, url: url)
    }
}

enum BookmarkError: LocalizedError {
    case invalidURL
    case fetchFailed
    case decodeFailed

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid URL"
        case .fetchFailed: return "Failed to fetch page"
        case .decodeFailed: return "Failed to decode page content"
        }
    }
}
