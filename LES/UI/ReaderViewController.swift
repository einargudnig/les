import Cocoa
import WebKit

class ReaderViewController: NSViewController {
    private(set) var textView: NSTextView!
    private var textScrollView: NSScrollView!
    private var webView: WKWebView!
    private var titleLabel: NSTextField!
    private var metaLabel: NSTextField!
    private var separatorView: NSView!
    private var containerView: NSView!

    private var currentRenderTask: Task<Void, Never>?
    private let renderer = ReaderRenderer()

    // Warm paper background
    private let readerBackground = NSColor(calibratedRed: 0.988, green: 0.984, blue: 0.976, alpha: 1.0)

    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d MMMM yyyy · h:mm a"
        return f
    }()

    override func loadView() {
        containerView = NSView()
        containerView.wantsLayer = true
        containerView.layer?.backgroundColor = readerBackground.cgColor

        // Header area
        titleLabel = NSTextField(labelWithString: "")
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 24, weight: .bold)
        titleLabel.lineBreakMode = .byWordWrapping
        titleLabel.maximumNumberOfLines = 4
        titleLabel.textColor = NSColor(calibratedWhite: 0.11, alpha: 1.0)
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        metaLabel = NSTextField(labelWithString: "")
        metaLabel.translatesAutoresizingMaskIntoConstraints = false
        metaLabel.font = .systemFont(ofSize: 12, weight: .regular)
        metaLabel.textColor = NSColor(calibratedWhite: 0.45, alpha: 1.0)
        metaLabel.alphaValue = 0.85

        separatorView = NSView()
        separatorView.translatesAutoresizingMaskIntoConstraints = false
        separatorView.wantsLayer = true
        separatorView.layer?.backgroundColor = NSColor(calibratedWhite: 0.0, alpha: 0.06).cgColor

        // Text view for RSS content
        textScrollView = NSScrollView()
        textScrollView.translatesAutoresizingMaskIntoConstraints = false
        textScrollView.hasVerticalScroller = true
        textScrollView.autohidesScrollers = true
        textScrollView.scrollerStyle = .overlay
        textScrollView.drawsBackground = true
        textScrollView.backgroundColor = readerBackground

        textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = true
        textView.backgroundColor = readerBackground
        textView.textContainerInset = NSSize(width: 32, height: 24)
        textView.isAutomaticLinkDetectionEnabled = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)

        textScrollView.documentView = textView

        // Web view for bookmarks
        let config = WKWebViewConfiguration()
        webView = WKWebView(frame: .zero, configuration: config)
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.isHidden = true

        containerView.addSubview(titleLabel)
        containerView.addSubview(metaLabel)
        containerView.addSubview(separatorView)
        containerView.addSubview(textScrollView)
        containerView.addSubview(webView)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 28),
            titleLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 32),
            titleLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -32),

            metaLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            metaLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 32),
            metaLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -32),

            separatorView.topAnchor.constraint(equalTo: metaLabel.bottomAnchor, constant: 20),
            separatorView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 32),
            separatorView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -32),
            separatorView.heightAnchor.constraint(equalToConstant: 1),

            // Text scroll view fills below separator
            textScrollView.topAnchor.constraint(equalTo: separatorView.bottomAnchor, constant: 4),
            textScrollView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
            textScrollView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            textScrollView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),

            // Web view fills below separator (same position, toggled via isHidden)
            webView.topAnchor.constraint(equalTo: separatorView.bottomAnchor, constant: 4),
            webView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
        ])

        self.view = containerView
    }

    func showItem(itemId: String) {
        currentRenderTask?.cancel()

        let store = ItemStore(db: DatabaseManager.shared.dbPool)
        guard let content = try? store.loadItemContent(id: itemId) else {
            clear()
            return
        }

        titleLabel.stringValue = content.title ?? "Untitled"

        var meta: [String] = []
        if let author = content.author {
            meta.append(author.uppercased())
        }
        if let ts = content.publishedAt {
            meta.append(dateFormatter.string(from: Date(timeIntervalSince1970: ts)))
        }
        if content.isBookmark, let urlStr = content.url, let host = URL(string: urlStr)?.host {
            meta.append(host)
        }
        metaLabel.stringValue = meta.joined(separator: "  ·  ")
        separatorView.isHidden = false

        if content.isBookmark, let urlStr = content.url, let url = URL(string: urlStr) {
            // Bookmark: load the full page in WKWebView
            showWebView()
            webView.load(URLRequest(url: url))
        } else {
            // RSS: render with text renderer
            showTextView()
            renderText(content: content, itemId: itemId)
        }
    }

    func clear() {
        currentRenderTask?.cancel()
        titleLabel.stringValue = ""
        metaLabel.stringValue = ""
        separatorView.isHidden = true
        textView.textStorage?.setAttributedString(NSAttributedString(string: ""))
        webView.loadHTMLString("", baseURL: nil)
        showTextView()
    }

    // MARK: - View switching

    private func showWebView() {
        textScrollView.isHidden = true
        webView.isHidden = false
    }

    private func showTextView() {
        webView.isHidden = true
        textScrollView.isHidden = false
    }

    // MARK: - Text rendering (RSS)

    private func renderText(content: ItemRecord.Content, itemId: String) {
        currentRenderTask = Task { [weak self] in
            guard let self else { return }

            // Check cache
            let cacheStore = ReaderCacheStore(db: DatabaseManager.shared.dbPool)
            if let cached = try? cacheStore.cached(itemId: itemId),
               let data = cached.renderedData,
               let attrStr = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSAttributedString.self, from: data) {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.textView.textStorage?.setAttributedString(attrStr)
                    self.textView.scrollToBeginningOfDocument(nil)
                }
                return
            }

            let html = content.contentHTML ?? content.summaryHTML ?? ""
            let attrStr = await renderer.render(html: html)

            guard !Task.isCancelled else { return }

            if let data = try? NSKeyedArchiver.archivedData(withRootObject: attrStr, requiringSecureCoding: false) {
                try? cacheStore.store(itemId: itemId, renderedData: data)
            }

            await MainActor.run {
                self.textView.textStorage?.setAttributedString(attrStr)
                self.textView.scrollToBeginningOfDocument(nil)
            }
        }
    }

    // MARK: - Vim scroll

    private let scrollStep: CGFloat = 60

    func scrollDown() {
        if !webView.isHidden {
            webView.evaluateJavaScript("window.scrollBy(0, 60)")
        } else {
            let clipView = textScrollView.contentView
            var origin = clipView.bounds.origin
            let maxY = (textScrollView.documentView?.frame.height ?? 0) - clipView.bounds.height
            origin.y = min(origin.y + scrollStep, max(maxY, 0))
            clipView.animator().setBoundsOrigin(origin)
        }
    }

    func scrollUp() {
        if !webView.isHidden {
            webView.evaluateJavaScript("window.scrollBy(0, -60)")
        } else {
            let clipView = textScrollView.contentView
            var origin = clipView.bounds.origin
            origin.y = max(origin.y - scrollStep, 0)
            clipView.animator().setBoundsOrigin(origin)
        }
    }
}
