import Foundation

struct ExtractedArticle {
    var title: String?
    var author: String?
    var contentHTML: String?
    var siteName: String?
    var publishedAt: TimeInterval?
}

final class ReadabilityExtractor {
    func extract(html: String, url: URL) -> ExtractedArticle {
        let doc: XMLDocument
        do {
            doc = try XMLDocument(xmlString: html, options: [.documentTidyHTML, .nodePreserveWhitespace])
        } catch {
            return ExtractedArticle()
        }

        let title = extractTitle(doc: doc)
        let author = extractAuthor(doc: doc)
        let siteName = extractSiteName(doc: doc)
        let contentHTML = extractContent(doc: doc)

        return ExtractedArticle(
            title: title,
            author: author,
            contentHTML: contentHTML,
            siteName: siteName
        )
    }

    // MARK: - Title

    private func extractTitle(doc: XMLDocument) -> String? {
        // Try og:title first
        if let ogTitle = metaContent(doc: doc, property: "og:title") {
            return ogTitle
        }
        // Try <title>
        if let title = try? doc.nodes(forXPath: "//title").first?.stringValue,
           !title.isEmpty {
            return title.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Try first h1
        if let h1 = try? doc.nodes(forXPath: "//h1").first?.stringValue {
            return h1.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    // MARK: - Author

    private func extractAuthor(doc: XMLDocument) -> String? {
        if let author = metaContent(doc: doc, name: "author") {
            return author
        }
        if let author = metaContent(doc: doc, property: "article:author") {
            return author
        }
        // Look for common byline patterns
        let bylineSelectors = [
            "//*[contains(@class, 'byline')]",
            "//*[contains(@class, 'author')]",
            "//*[@rel='author']",
        ]
        for selector in bylineSelectors {
            if let node = try? doc.nodes(forXPath: selector).first,
               let text = node.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty, text.count < 100 {
                return text
            }
        }
        return nil
    }

    // MARK: - Site Name

    private func extractSiteName(doc: XMLDocument) -> String? {
        metaContent(doc: doc, property: "og:site_name")
    }

    // MARK: - Content Extraction

    private func extractContent(doc: XMLDocument) -> String? {
        // 1. Try <article> tag first
        if let article = try? doc.nodes(forXPath: "//article").first as? XMLElement {
            return cleanedHTML(from: article)
        }

        // 2. Try [role="main"]
        if let main = try? doc.nodes(forXPath: "//*[@role='main']").first as? XMLElement {
            return cleanedHTML(from: main)
        }

        // 3. Try <main> tag
        if let main = try? doc.nodes(forXPath: "//main").first as? XMLElement {
            return cleanedHTML(from: main)
        }

        // 4. Score divs by text density
        guard let body = try? doc.nodes(forXPath: "//body").first as? XMLElement else {
            return nil
        }

        var bestNode: XMLElement?
        var bestScore: Double = 0

        scoreNodes(element: body, bestNode: &bestNode, bestScore: &bestScore)

        if let best = bestNode {
            return cleanedHTML(from: best)
        }

        return nil
    }

    private func scoreNodes(element: XMLElement, bestNode: inout XMLElement?, bestScore: inout Double) {
        let tagName = element.name?.lowercased() ?? ""

        // Skip non-content tags
        let skipTags: Set = ["nav", "footer", "header", "aside", "script", "style", "form", "noscript"]
        if skipTags.contains(tagName) { return }

        // Skip elements with non-content classes
        let classAttr = (element.attribute(forName: "class")?.stringValue ?? "").lowercased()
        let idAttr = (element.attribute(forName: "id")?.stringValue ?? "").lowercased()
        let skipPatterns = ["nav", "footer", "sidebar", "menu", "comment", "widget", "ad-", "social", "share", "related"]
        if skipPatterns.contains(where: { classAttr.contains($0) || idAttr.contains($0) }) {
            return
        }

        if tagName == "div" || tagName == "section" {
            let text = element.stringValue ?? ""
            let textLength = Double(text.count)
            let pCount = Double((try? element.nodes(forXPath: ".//p")).map(\.count) ?? 0)
            let score = textLength * 0.1 + pCount * 50

            if score > bestScore {
                bestScore = score
                bestNode = element
            }
        }

        for child in element.children ?? [] {
            if let childElement = child as? XMLElement {
                scoreNodes(element: childElement, bestNode: &bestNode, bestScore: &bestScore)
            }
        }
    }

    // MARK: - HTML Cleaning

    private func cleanedHTML(from element: XMLElement) -> String? {
        removeUnwantedElements(from: element)
        return element.xmlString(options: [.nodePreserveWhitespace])
    }

    private func removeUnwantedElements(from element: XMLElement) {
        let removeTags: Set = ["script", "style", "nav", "footer", "aside", "header",
                                "iframe", "noscript", "form", "svg"]
        let removeClasses = ["nav", "footer", "sidebar", "menu", "comment", "widget",
                             "ad-", "social", "share", "related", "popup", "modal"]

        var toRemove: [XMLNode] = []

        for child in element.children ?? [] {
            guard let childElement = child as? XMLElement else { continue }
            let tag = childElement.name?.lowercased() ?? ""
            let cls = (childElement.attribute(forName: "class")?.stringValue ?? "").lowercased()
            let idVal = (childElement.attribute(forName: "id")?.stringValue ?? "").lowercased()

            if removeTags.contains(tag) {
                toRemove.append(child)
            } else if removeClasses.contains(where: { cls.contains($0) || idVal.contains($0) }) {
                toRemove.append(child)
            } else {
                removeUnwantedElements(from: childElement)
            }
        }

        for node in toRemove {
            element.removeChild(at: node.index)
        }
    }

    // MARK: - Meta Helpers

    private func metaContent(doc: XMLDocument, property: String) -> String? {
        let xpath = "//meta[@property='\(property)']/@content"
        if let val = try? doc.nodes(forXPath: xpath).first?.stringValue,
           !val.isEmpty {
            return val.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    private func metaContent(doc: XMLDocument, name: String) -> String? {
        let xpath = "//meta[@name='\(name)']/@content"
        if let val = try? doc.nodes(forXPath: xpath).first?.stringValue,
           !val.isEmpty {
            return val.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }
}
