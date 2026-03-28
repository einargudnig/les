import Cocoa

final class ReaderRenderer: Sendable {
    func render(html: String) async -> NSAttributedString {
        // Capture appearance on main thread
        let isDark = await MainActor.run {
            NSApp.effectiveAppearance.isDark
        }
        return await Task.detached(priority: .userInitiated) {
            Self.renderSync(html: html, isDark: isDark)
        }.value
    }

    private static func renderSync(html: String, isDark: Bool) -> NSAttributedString {
        let sanitized = sanitizeHTML(html)
        let css = Theme.readerCSS(isDark: isDark)

        let wrapped = """
        <html>
        <head><style>\(css)</style></head>
        <body>\(sanitized)</body>
        </html>
        """

        guard let data = wrapped.data(using: .utf8) else {
            return NSAttributedString(string: html)
        }

        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue,
        ]

        if let attrStr = try? NSAttributedString(data: data, options: options, documentAttributes: nil) {
            return attrStr
        }

        return NSAttributedString(string: stripTags(html))
    }

    private static func sanitizeHTML(_ html: String) -> String {
        var result = html
        result = result.replacingOccurrences(of: "<script[^>]*>.*?</script>", with: "", options: [.regularExpression, .caseInsensitive])
        result = result.replacingOccurrences(of: "<style[^>]*>.*?</style>", with: "", options: [.regularExpression, .caseInsensitive])
        result = result.replacingOccurrences(of: "\\s+on\\w+\\s*=\\s*\"[^\"]*\"", with: "", options: [.regularExpression, .caseInsensitive])
        result = result.replacingOccurrences(of: "\\s+on\\w+\\s*=\\s*'[^']*'", with: "", options: [.regularExpression, .caseInsensitive])
        result = result.replacingOccurrences(of: "<iframe[^>]*>.*?</iframe>", with: "", options: [.regularExpression, .caseInsensitive])
        return result
    }

    private static func stripTags(_ html: String) -> String {
        html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    }
}
