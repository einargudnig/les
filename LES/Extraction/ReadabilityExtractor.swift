import Foundation

struct ExtractedArticle {
    var title: String?
    var author: String?
    var contentHTML: String?
    var siteName: String?
    var publishedAt: TimeInterval?
}

final class ReadabilityExtractor {
    // Tags that are never content
    private let junkTags: Set<String> = [
        "script", "style", "noscript", "iframe", "svg", "form",
        "button", "input", "select", "textarea", "label",
        "nav", "footer", "header", "aside",
    ]

    // Class/id patterns that indicate non-content
    private let junkPatterns: [String] = [
        "nav", "footer", "sidebar", "menu", "comment", "widget",
        "ad-", "ads", "social", "share", "related", "popup", "modal",
        "cookie", "banner", "promo", "newsletter", "signup",
        "breadcrumb", "pagination", "toolbar",
    ]

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
        if let ogTitle = metaContent(doc: doc, property: "og:title") {
            return ogTitle
        }
        if let h1 = try? doc.nodes(forXPath: "//h1").first?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
           !h1.isEmpty {
            return h1
        }
        if let title = try? doc.nodes(forXPath: "//title").first?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty {
            // Strip site name suffix (e.g., "Article Title - Site Name")
            let separators = [" | ", " - ", " – ", " — ", " :: "]
            for sep in separators {
                if let range = title.range(of: sep, options: .backwards) {
                    let candidate = String(title[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
                    if candidate.count > 10 { return candidate }
                }
            }
            return title
        }
        return nil
    }

    // MARK: - Author

    private func extractAuthor(doc: XMLDocument) -> String? {
        if let author = metaContent(doc: doc, name: "author") { return author }
        if let author = metaContent(doc: doc, property: "article:author") { return author }

        let bylineSelectors = [
            "//*[contains(@class, 'byline')]",
            "//*[contains(@class, 'author')]",
            "//*[contains(@itemprop, 'author')]",
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
        guard let body = try? doc.nodes(forXPath: "//body").first as? XMLElement else {
            return nil
        }

        // First, strip all junk from body
        stripJunk(from: body)

        // Try specific content containers first
        let candidates: [XMLElement] = findCandidates(in: body)

        // Score each candidate
        var bestNode: XMLElement?
        var bestScore: Double = 0

        for candidate in candidates {
            let score = scoreCandidate(candidate)
            if score > bestScore {
                bestScore = score
                bestNode = candidate
            }
        }

        // Also score all divs/sections/articles in the tree
        scoreDeeply(element: body, bestNode: &bestNode, bestScore: &bestScore, depth: 0)

        let winner = bestNode ?? body

        // Clean the winner and return
        stripJunk(from: winner)
        let html = winner.xmlString(options: [.nodePreserveWhitespace])

        // If result is too short, it's probably not useful content
        let plainText = html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if plainText.count < 50 { return nil }

        return html
    }

    private func findCandidates(in body: XMLElement) -> [XMLElement] {
        var candidates: [XMLElement] = []

        // article tags
        if let nodes = try? body.nodes(forXPath: ".//article") {
            candidates.append(contentsOf: nodes.compactMap { $0 as? XMLElement })
        }

        // Common content class patterns
        let contentSelectors = [
            ".//*[contains(@class, 'article-content')]",
            ".//*[contains(@class, 'article-body')]",
            ".//*[contains(@class, 'post-content')]",
            ".//*[contains(@class, 'post-body')]",
            ".//*[contains(@class, 'entry-content')]",
            ".//*[contains(@class, 'story-body')]",
            ".//*[contains(@class, 'page-content')]",
            ".//*[contains(@itemprop, 'articleBody')]",
            ".//*[@role='article']",
        ]
        for selector in contentSelectors {
            if let nodes = try? body.nodes(forXPath: selector) {
                candidates.append(contentsOf: nodes.compactMap { $0 as? XMLElement })
            }
        }

        return candidates
    }

    private func scoreCandidate(_ element: XMLElement) -> Double {
        let text = element.stringValue ?? ""
        let textLen = Double(text.count)
        guard textLen > 100 else { return 0 } // Too short to be content

        // Count content-bearing elements
        let pCount = Double(countDescendants(element, tag: "p"))
        let hCount = Double(countDescendants(element, tags: ["h1", "h2", "h3", "h4"]))
        let listCount = Double(countDescendants(element, tags: ["ul", "ol"]))
        let blockquoteCount = Double(countDescendants(element, tag: "blockquote"))
        let imgCount = Double(countDescendants(element, tag: "img"))

        // Count links (high link density = navigation, not content)
        let linkCount = Double(countDescendants(element, tag: "a"))
        let linkText = descendantText(element, tag: "a")
        let linkDensity = textLen > 0 ? Double(linkText.count) / textLen : 0

        // Score formula
        var score: Double = 0
        score += pCount * 30          // Paragraphs are strong signal
        score += textLen * 0.05       // More text is better
        score += hCount * 10          // Headings indicate structure
        score += listCount * 5        // Lists are content
        score += blockquoteCount * 10 // Quotes are content
        score += imgCount * 5         // Images suggest article

        // Penalize high link density (navigation)
        if linkDensity > 0.4 {
            score *= 0.2
        } else if linkDensity > 0.25 {
            score *= 0.5
        }

        // Penalize very short content
        if pCount < 2 && textLen < 500 {
            score *= 0.3
        }

        return score
    }

    private func scoreDeeply(element: XMLElement, bestNode: inout XMLElement?, bestScore: inout Double, depth: Int) {
        let tag = element.name?.lowercased() ?? ""

        if tag == "div" || tag == "section" || tag == "article" || tag == "main" {
            if !isJunkElement(element) {
                let score = scoreCandidate(element)
                if score > bestScore {
                    bestScore = score
                    bestNode = element
                }
            }
        }

        // Don't go too deep
        guard depth < 15 else { return }

        for child in element.children ?? [] {
            if let childElement = child as? XMLElement {
                scoreDeeply(element: childElement, bestNode: &bestNode, bestScore: &bestScore, depth: depth + 1)
            }
        }
    }

    // MARK: - Junk Removal

    private func stripJunk(from element: XMLElement) {
        var toRemove: [XMLNode] = []

        for child in element.children ?? [] {
            guard let childElement = child as? XMLElement else { continue }

            if shouldRemove(childElement) {
                toRemove.append(child)
            } else {
                stripJunk(from: childElement)
            }
        }

        // Remove in reverse to keep indexes stable
        for node in toRemove.reversed() {
            node.detach()
        }
    }

    private func shouldRemove(_ element: XMLElement) -> Bool {
        let tag = element.name?.lowercased() ?? ""
        if junkTags.contains(tag) { return true }
        if isJunkElement(element) { return true }

        // Remove hidden elements
        let style = element.attribute(forName: "style")?.stringValue?.lowercased() ?? ""
        if style.contains("display:none") || style.contains("display: none") ||
           style.contains("visibility:hidden") || style.contains("visibility: hidden") {
            return true
        }

        // Remove aria-hidden
        if element.attribute(forName: "aria-hidden")?.stringValue == "true" {
            return true
        }

        return false
    }

    private func isJunkElement(_ element: XMLElement) -> Bool {
        let cls = (element.attribute(forName: "class")?.stringValue ?? "").lowercased()
        let id = (element.attribute(forName: "id")?.stringValue ?? "").lowercased()
        let role = (element.attribute(forName: "role")?.stringValue ?? "").lowercased()

        if role == "navigation" || role == "banner" || role == "contentinfo" {
            return true
        }

        return junkPatterns.contains(where: { cls.contains($0) || id.contains($0) })
    }

    // MARK: - Helpers

    private func countDescendants(_ element: XMLElement, tag: String) -> Int {
        (try? element.nodes(forXPath: ".//\(tag)"))?.count ?? 0
    }

    private func countDescendants(_ element: XMLElement, tags: [String]) -> Int {
        tags.reduce(0) { $0 + countDescendants(element, tag: $1) }
    }

    private func descendantText(_ element: XMLElement, tag: String) -> String {
        let nodes = (try? element.nodes(forXPath: ".//\(tag)")) ?? []
        return nodes.compactMap { $0.stringValue }.joined()
    }

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
