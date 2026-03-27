import Foundation

enum FetchResult {
    case fetched(data: Data, etag: String?, lastModified: String?)
    case notModified
}

actor FeedFetcher {
    private let session: URLSession
    private let maxConcurrent = 4
    private var inFlight = 0

    init(session: URLSession? = nil) {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        config.httpMaximumConnectionsPerHost = 4
        self.session = session ?? URLSession(configuration: config)
    }

    func fetch(url: URL, etag: String?, lastModified: String?) async throws -> FetchResult {
        var request = URLRequest(url: url)
        request.setValue("LES/1.0 (macOS RSS Reader)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/rss+xml, application/atom+xml, application/xml, text/xml", forHTTPHeaderField: "Accept")

        if let etag {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        if let lastModified {
            request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since")
        }

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw FeedFetchError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200:
            let newEtag = httpResponse.value(forHTTPHeaderField: "ETag")
            let newLastModified = httpResponse.value(forHTTPHeaderField: "Last-Modified")
            return .fetched(data: data, etag: newEtag, lastModified: newLastModified)
        case 304:
            return .notModified
        case 400...499:
            throw FeedFetchError.clientError(httpResponse.statusCode)
        case 500...599:
            throw FeedFetchError.serverError(httpResponse.statusCode)
        default:
            throw FeedFetchError.unexpectedStatus(httpResponse.statusCode)
        }
    }

    func refreshAll(
        feeds: [FeedRecord],
        feedStore: FeedStore,
        parser: FeedParser,
        ingestService: IngestService
    ) async {
        await withTaskGroup(of: Void.self) { group in
            // Semaphore-style concurrency limiting via chunks
            var feedQueue = feeds[...]
            let semaphore = AsyncSemaphore(limit: maxConcurrent)

            for feed in feeds {
                group.addTask {
                    await semaphore.wait()
                    defer { Task { await semaphore.signal() } }
                    await self.refreshSingleFeed(feed, feedStore: feedStore, parser: parser, ingestService: ingestService)
                }
            }
        }
    }

    private func refreshSingleFeed(
        _ feed: FeedRecord,
        feedStore: FeedStore,
        parser: FeedParser,
        ingestService: IngestService
    ) async {
        guard let feedId = feed.id, let feedURL = URL(string: feed.url) else { return }

        do {
            let result = try await fetch(url: feedURL, etag: feed.etag, lastModified: feed.lastModified)

            switch result {
            case .notModified:
                try feedStore.updateFeedMeta(
                    id: feedId,
                    title: nil,
                    siteURL: nil,
                    etag: feed.etag,
                    lastModified: feed.lastModified,
                    lastFetchedAt: Date().timeIntervalSince1970
                )

            case let .fetched(data, etag, lastModified):
                let parsed = try parser.parse(data: data, feedURL: feedURL)
                try ingestService.ingest(feedId: feedId, parsed: parsed)
                try feedStore.updateFeedMeta(
                    id: feedId,
                    title: parsed.title,
                    siteURL: parsed.siteURL,
                    etag: etag,
                    lastModified: lastModified,
                    lastFetchedAt: Date().timeIntervalSince1970
                )
            }
        } catch {
            try? feedStore.recordFeedError(id: feedId, error: error.localizedDescription)
        }
    }
}

enum FeedFetchError: LocalizedError {
    case invalidResponse
    case clientError(Int)
    case serverError(Int)
    case unexpectedStatus(Int)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Invalid response"
        case .clientError(let code): return "Client error: \(code)"
        case .serverError(let code): return "Server error: \(code)"
        case .unexpectedStatus(let code): return "Unexpected status: \(code)"
        }
    }
}

/// Simple async semaphore for concurrency limiting
actor AsyncSemaphore {
    private let limit: Int
    private var count: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        self.limit = limit
        self.count = limit
    }

    func wait() async {
        if count > 0 {
            count -= 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func signal() {
        if !waiters.isEmpty {
            let waiter = waiters.removeFirst()
            waiter.resume()
        } else {
            count += 1
        }
    }
}
