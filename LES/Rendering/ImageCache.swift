import Foundation
import Cocoa
import CryptoKit

actor ImageCache {
    static let shared = ImageCache()

    private let cacheDir: URL

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        cacheDir = appSupport.appendingPathComponent("LES/images", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    func image(for url: URL) async -> NSImage? {
        // Check disk cache
        let key = cacheKey(for: url)
        let filePath = cacheDir.appendingPathComponent(key)

        if let data = try? Data(contentsOf: filePath),
           let image = NSImage(data: data) {
            return image
        }

        // Download
        do {
            var request = URLRequest(url: url)
            request.setValue("LES/1.0", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                return nil
            }

            guard let image = NSImage(data: data) else { return nil }

            // Cache to disk
            try? data.write(to: filePath)

            return image
        } catch {
            return nil
        }
    }

    private func cacheKey(for url: URL) -> String {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
