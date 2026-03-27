import Cocoa

final class ReaderRenderer: Sendable {
    func render(html: String) async -> NSAttributedString {
        await Task.detached(priority: .userInitiated) {
            Self.renderSync(html: html)
        }.value
    }

    private static func renderSync(html: String) -> NSAttributedString {
        let sanitized = sanitizeHTML(html)

        // Wrap in editorial-quality HTML with refined typography
        let wrapped = """
        <html>
        <head>
        <style>
        body {
            font-family: "New York", "Iowan Old Style", Georgia, serif;
            font-size: 16.5px;
            line-height: 1.75;
            color: #2C2C2E;
            max-width: 640px;
            -webkit-font-smoothing: antialiased;
        }
        p {
            margin-bottom: 1.1em;
        }
        h1, h2, h3, h4 {
            font-family: -apple-system, "SF Pro Display", "Helvetica Neue", sans-serif;
            font-weight: 700;
            color: #1C1C1E;
            letter-spacing: -0.02em;
            line-height: 1.25;
            margin-top: 1.8em;
            margin-bottom: 0.6em;
        }
        h1 { font-size: 26px; }
        h2 { font-size: 22px; }
        h3 { font-size: 18px; }
        a {
            color: #8B572A;
            text-decoration: none;
            border-bottom: 1px solid rgba(139, 87, 42, 0.25);
        }
        a:hover {
            border-bottom-color: #8B572A;
        }
        pre, code {
            font-family: "SF Mono", "Menlo", "Monaco", monospace;
            font-size: 14px;
        }
        code {
            background-color: rgba(0, 0, 0, 0.04);
            padding: 2px 5px;
            border-radius: 6px;
            color: #3C3C3E;
        }
        pre {
            background-color: #F8F7F5;
            padding: 16px 20px;
            border-radius: 10px;
            overflow-x: auto;
            border: 1px solid rgba(0, 0, 0, 0.06);
            line-height: 1.5;
        }
        pre code {
            background: none;
            padding: 0;
            border-radius: 0;
        }
        blockquote {
            margin: 1.4em 0;
            margin-left: 0;
            padding: 0 0 0 20px;
            border-left: 2px solid #C4A882;
            color: #636366;
            font-style: italic;
        }
        ul, ol {
            padding-left: 1.6em;
            margin-bottom: 1.1em;
        }
        li {
            margin-bottom: 0.4em;
        }
        hr {
            border: none;
            border-top: 1px solid rgba(0, 0, 0, 0.08);
            margin: 2em 0;
        }
        strong {
            font-weight: 600;
            color: #1C1C1E;
        }
        img {
            max-width: 100%;
            height: auto;
            border-radius: 8px;
            margin: 0.8em 0;
            display: block;
        }
        figure {
            margin: 1.2em 0;
            padding: 0;
        }
        figcaption {
            font-size: 13px;
            color: #888;
            margin-top: 6px;
            text-align: center;
        }
        </style>
        </head>
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

        // Remove script tags
        result = result.replacingOccurrences(
            of: "<script[^>]*>.*?</script>",
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        // Remove style tags
        result = result.replacingOccurrences(
            of: "<style[^>]*>.*?</style>",
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        // Remove event handlers
        result = result.replacingOccurrences(
            of: "\\s+on\\w+\\s*=\\s*\"[^\"]*\"",
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        result = result.replacingOccurrences(
            of: "\\s+on\\w+\\s*=\\s*'[^']*'",
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        // Remove iframe
        result = result.replacingOccurrences(
            of: "<iframe[^>]*>.*?</iframe>",
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )

        return result
    }

    private static func stripTags(_ html: String) -> String {
        html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    }
}
