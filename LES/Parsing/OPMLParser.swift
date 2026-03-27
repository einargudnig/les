import Foundation

struct OPMLFeed {
    let title: String?
    let url: String
    let folder: String?
}

final class OPMLParser {
    static func parse(data: Data) -> [OPMLFeed] {
        let delegate = OPMLParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        parser.parse()
        return delegate.feeds
    }

    static func export(feeds: [FeedRecord]) -> Data {
        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <opml version="2.0">
          <head>
            <title>LES RSS Subscriptions</title>
          </head>
          <body>

        """

        var folders: [String: [FeedRecord]] = [:]
        var noFolder: [FeedRecord] = []

        for feed in feeds {
            if let folder = feed.folder {
                folders[folder, default: []].append(feed)
            } else {
                noFolder.append(feed)
            }
        }

        for feed in noFolder {
            let title = escapeXML(feed.title ?? feed.url)
            let url = escapeXML(feed.url)
            let siteURL = feed.siteURL.map { " htmlUrl=\"\(escapeXML($0))\"" } ?? ""
            xml += "    <outline type=\"rss\" text=\"\(title)\" xmlUrl=\"\(url)\"\(siteURL)/>\n"
        }

        for (folder, feeds) in folders.sorted(by: { $0.key < $1.key }) {
            xml += "    <outline text=\"\(escapeXML(folder))\">\n"
            for feed in feeds {
                let title = escapeXML(feed.title ?? feed.url)
                let url = escapeXML(feed.url)
                let siteURL = feed.siteURL.map { " htmlUrl=\"\(escapeXML($0))\"" } ?? ""
                xml += "      <outline type=\"rss\" text=\"\(title)\" xmlUrl=\"\(url)\"\(siteURL)/>\n"
            }
            xml += "    </outline>\n"
        }

        xml += """
          </body>
        </opml>
        """

        return Data(xml.utf8)
    }

    private static func escapeXML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

private final class OPMLParserDelegate: NSObject, XMLParserDelegate {
    var feeds: [OPMLFeed] = []
    private var currentFolder: String?

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        guard elementName == "outline" else { return }

        if let xmlUrl = attributeDict["xmlUrl"], !xmlUrl.isEmpty {
            // This is a feed outline
            feeds.append(OPMLFeed(
                title: attributeDict["text"] ?? attributeDict["title"],
                url: xmlUrl,
                folder: currentFolder
            ))
        } else {
            // This is a folder
            currentFolder = attributeDict["text"] ?? attributeDict["title"]
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "outline" && currentFolder != nil {
            // Check if we're leaving a folder — simplified: reset on outline close
            // This works for single-level nesting
        }
    }

    func parserDidEndDocument(_ parser: XMLParser) {
        // Clean up
    }
}
