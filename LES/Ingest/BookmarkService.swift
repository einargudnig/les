import Foundation
import GRDB
import CryptoKit

actor BookmarkService {
    private let extractor = ReadabilityExtractor()

    func addBookmark(url: String, db: DatabasePool) async throws {
        let bookmarkStore = BookmarkStore(db: db)

        // Check for duplicate
        if try bookmarkStore.bookmarkByURL(url) != nil {
            return // already bookmarked
        }

        // Insert bookmark record immediately
        let bookmark = try bookmarkStore.insertBookmark(url: url)
        guard let bookmarkId = bookmark.id else { return }

        // Fetch and extract
        do {
            let extracted = try await fetchAndExtract(urlString: url)

            // Create item
            let stableId = ItemRecord.bookmarkStableID(url: url)
            let item = ItemRecord(
                id: stableId,
                feedId: nil,
                bookmarkId: bookmarkId,
                title: extracted.title ?? url,
                author: extracted.author,
                url: url,
                publishedAt: extracted.publishedAt ?? Date().timeIntervalSince1970,
                updatedAt: Date().timeIntervalSince1970,
                contentHTML: extracted.contentHTML
            )

            try await db.write { db in
                try item.insert(db)
            }

            try bookmarkStore.updateExtraction(id: bookmarkId, siteName: extracted.siteName)
        } catch {
            // Extraction failed — create item with error message
            let stableId = ItemRecord.bookmarkStableID(url: url)
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
            try? await db.write { db in
                try item.insert(db)
            }
        }
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
