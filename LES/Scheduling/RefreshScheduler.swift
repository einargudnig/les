import Foundation
import Cocoa

actor RefreshScheduler {
    static let shared = RefreshScheduler()

    private var timer: Timer?
    private var isRefreshing = false
    private var refreshInterval: TimeInterval = 30 * 60 // 30 minutes

    private let fetcher = FeedFetcher()
    private let parser = FeedParser()

    func start() {
        // Refresh on launch
        Task { await refreshAllFeeds() }

        // Schedule periodic refresh
        Task { @MainActor in
            Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { _ in
                Task { await RefreshScheduler.shared.refreshAllFeeds() }
            }
        }

        // Observe app becoming active
        Task { @MainActor in
            NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { _ in
                Task { await RefreshScheduler.shared.refreshAllFeedsIfStale() }
            }
        }
    }

    func refreshAllFeeds() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            let feedStore = FeedStore(db: DatabaseManager.shared.dbPool)
            let ingestService = IngestService(db: DatabaseManager.shared.dbPool)
            let feeds = try feedStore.allFeedsForRefresh()

            // Filter feeds that need refresh based on backoff
            let now = Date().timeIntervalSince1970
            let dueFeeds = feeds.filter { feed in
                guard let lastFetched = feed.lastFetchedAt else { return true }
                let backoff = Self.backoffInterval(errorCount: feed.errorCount)
                return now - lastFetched > backoff
            }

            await fetcher.refreshAll(
                feeds: dueFeeds,
                feedStore: feedStore,
                parser: parser,
                ingestService: ingestService
            )
        } catch {
            // Log but don't crash
        }
    }

    func refreshFeed(id: Int64) async {
        do {
            let feedStore = FeedStore(db: DatabaseManager.shared.dbPool)
            let ingestService = IngestService(db: DatabaseManager.shared.dbPool)
            guard let feed = try feedStore.feed(id: id) else { return }

            await fetcher.refreshAll(
                feeds: [feed],
                feedStore: feedStore,
                parser: parser,
                ingestService: ingestService
            )
        } catch {
            // Log but don't crash
        }
    }

    private func refreshAllFeedsIfStale() async {
        // Only refresh if last refresh was more than 5 minutes ago
        do {
            let feedStore = FeedStore(db: DatabaseManager.shared.dbPool)
            let feeds = try feedStore.allFeedsForRefresh()
            let now = Date().timeIntervalSince1970
            let anyStale = feeds.contains { feed in
                guard let lastFetched = feed.lastFetchedAt else { return true }
                return now - lastFetched > 5 * 60
            }
            if anyStale {
                await refreshAllFeeds()
            }
        } catch {}
    }

    private static func backoffInterval(errorCount: Int) -> TimeInterval {
        switch errorCount {
        case 0: return 0
        case 1: return 15 * 60        // 15 min
        case 2: return 60 * 60         // 1 hour
        case 3: return 6 * 60 * 60     // 6 hours
        default: return 24 * 60 * 60   // 24 hours cap
        }
    }
}
