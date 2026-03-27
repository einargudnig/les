import Foundation

struct ParsedFeed {
    var title: String?
    var siteURL: String?
    var items: [ParsedItem]
}

struct ParsedItem {
    var title: String?
    var link: String?
    var externalId: String?
    var author: String?
    var publishedAt: TimeInterval?
    var summaryHTML: String?
    var contentHTML: String?
}

final class FeedParser {
    func parse(data: Data, feedURL: URL) throws -> ParsedFeed {
        let delegate = FeedParserDelegate(feedURL: feedURL)
        let xmlParser = XMLParser(data: data)
        xmlParser.delegate = delegate
        xmlParser.shouldResolveExternalEntities = false

        guard xmlParser.parse() else {
            if let error = xmlParser.parserError {
                throw error
            }
            throw FeedParseError.unknownFormat
        }

        guard let result = delegate.result else {
            throw FeedParseError.unknownFormat
        }

        return result
    }
}

enum FeedParseError: LocalizedError {
    case unknownFormat

    var errorDescription: String? {
        switch self {
        case .unknownFormat: return "Unknown feed format"
        }
    }
}

// MARK: - XMLParser Delegate

private final class FeedParserDelegate: NSObject, XMLParserDelegate {
    let feedURL: URL
    var result: ParsedFeed?

    private enum FeedType {
        case rss
        case atom
    }

    private var feedType: FeedType?
    private var feedTitle: String?
    private var feedSiteURL: String?
    private var items: [ParsedItem] = []

    // Current item being parsed
    private var currentItem: ParsedItem?
    private var isInItem = false
    private var isInChannel = false

    // Current element text accumulation
    private var currentText = ""
    private var currentElementName: String?

    // Atom link attributes
    private var atomLinkRel: String?
    private var atomLinkHref: String?

    init(feedURL: URL) {
        self.feedURL = feedURL
    }

    func parserDidStartDocument(_ parser: XMLParser) {
        items = []
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        currentText = ""
        currentElementName = elementName

        switch elementName {
        case "rss":
            feedType = .rss
        case "feed":
            if feedType == nil { feedType = .atom }
        case "channel":
            isInChannel = true
        case "item":
            // RSS item
            isInItem = true
            currentItem = ParsedItem()
        case "entry":
            // Atom entry
            isInItem = true
            currentItem = ParsedItem()
        case "link":
            if feedType == .atom {
                atomLinkRel = attributeDict["rel"] ?? "alternate"
                atomLinkHref = attributeDict["href"]
                if isInItem {
                    if atomLinkRel == "alternate", let href = atomLinkHref {
                        currentItem?.link = resolveURL(href)
                    }
                } else {
                    if atomLinkRel == "alternate", let href = atomLinkHref {
                        feedSiteURL = resolveURL(href)
                    }
                }
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if let str = String(data: CDATABlock, encoding: .utf8) {
            currentText += str
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)

        if isInItem {
            // Inside an item/entry
            switch elementName {
            case "title":
                if currentItem?.title == nil { currentItem?.title = text }
            case "link":
                if feedType == .rss, currentItem?.link == nil {
                    currentItem?.link = resolveURL(text)
                }
            case "guid", "id":
                currentItem?.externalId = text
            case "pubDate":
                currentItem?.publishedAt = parseDate(text)
            case "published":
                if currentItem?.publishedAt == nil {
                    currentItem?.publishedAt = parseDate(text)
                }
            case "updated":
                if currentItem?.publishedAt == nil {
                    currentItem?.publishedAt = parseDate(text)
                }
            case "description":
                if feedType == .rss {
                    currentItem?.summaryHTML = text
                }
            case "content:encoded", "content":
                currentItem?.contentHTML = text
            case "summary":
                if feedType == .atom {
                    currentItem?.summaryHTML = text
                }
            case "author", "dc:creator":
                currentItem?.author = text
            case "name":
                // Atom author/name
                if currentItem?.author == nil {
                    currentItem?.author = text
                }
            case "item", "entry":
                if let item = currentItem {
                    items.append(item)
                }
                currentItem = nil
                isInItem = false
            default:
                break
            }
        } else {
            // Feed-level elements
            switch elementName {
            case "title":
                if feedTitle == nil { feedTitle = text }
            case "link":
                if feedType == .rss, feedSiteURL == nil {
                    feedSiteURL = resolveURL(text)
                }
            case "channel":
                isInChannel = false
            default:
                break
            }
        }

        currentText = ""
    }

    func parserDidEndDocument(_ parser: XMLParser) {
        result = ParsedFeed(
            title: feedTitle,
            siteURL: feedSiteURL,
            items: items
        )
    }

    // MARK: - Helpers

    private func resolveURL(_ href: String) -> String {
        if href.hasPrefix("http://") || href.hasPrefix("https://") {
            return href
        }
        return URL(string: href, relativeTo: feedURL)?.absoluteString ?? href
    }

    private func parseDate(_ string: String) -> TimeInterval? {
        // Try RFC 2822 (RSS)
        if let date = DateFormatters.rfc2822.date(from: string) {
            return date.timeIntervalSince1970
        }
        // Try ISO 8601 (Atom)
        if let date = DateFormatters.iso8601.date(from: string) {
            return date.timeIntervalSince1970
        }
        // Try ISO 8601 with fractional seconds
        if let date = DateFormatters.iso8601Fractional.date(from: string) {
            return date.timeIntervalSince1970
        }
        return nil
    }
}

private enum DateFormatters {
    static let rfc2822: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return f
    }()

    static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static let iso8601Fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
