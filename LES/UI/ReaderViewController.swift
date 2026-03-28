import Cocoa
import WebKit

class ReaderViewController: NSViewController {
    private(set) var textView: NSTextView!
    private var textScrollView: NSScrollView!
    private var webView: WKWebView?
    private var emptyStateView: NSView!
    private var titleLabel: NSTextField!
    private var metaLabel: NSTextField!
    private var separatorView: NSView!
    private var containerView: NSView!
    private var contentArea: NSView! // wraps both text and web views

    private var currentRenderTask: Task<Void, Never>?
    private let renderer = ReaderRenderer()

    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d MMMM yyyy · h:mm a"
        return f
    }()

    override func loadView() {
        containerView = NSView()
        containerView.wantsLayer = true

        // Header area
        titleLabel = NSTextField(labelWithString: "")
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = Theme.readerTitleFont
        titleLabel.lineBreakMode = .byWordWrapping
        titleLabel.maximumNumberOfLines = 4
        titleLabel.textColor = Theme.primaryText
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        metaLabel = NSTextField(labelWithString: "")
        metaLabel.translatesAutoresizingMaskIntoConstraints = false
        metaLabel.font = Theme.readerMetaFont
        metaLabel.textColor = Theme.secondaryText
        metaLabel.alphaValue = 0.85

        separatorView = NSView()
        separatorView.translatesAutoresizingMaskIntoConstraints = false
        separatorView.wantsLayer = true
        separatorView.layer?.backgroundColor = Theme.separator.cgColor

        // Content area (holds text scroll view, web view gets added here lazily)
        contentArea = NSView()
        contentArea.translatesAutoresizingMaskIntoConstraints = false

        // Text view for RSS content
        textScrollView = NSScrollView()
        textScrollView.translatesAutoresizingMaskIntoConstraints = false
        textScrollView.hasVerticalScroller = true
        textScrollView.autohidesScrollers = true
        textScrollView.scrollerStyle = .overlay
        textScrollView.drawsBackground = true
        textScrollView.backgroundColor = Theme.readerBackground

        textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = true
        textView.backgroundColor = Theme.readerBackground
        textView.textContainerInset = NSSize(width: Theme.spacingXXL, height: Theme.spacingXL)
        textView.isAutomaticLinkDetectionEnabled = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)

        textScrollView.documentView = textView
        contentArea.addSubview(textScrollView)

        NSLayoutConstraint.activate([
            textScrollView.topAnchor.constraint(equalTo: contentArea.topAnchor),
            textScrollView.bottomAnchor.constraint(equalTo: contentArea.bottomAnchor),
            textScrollView.leadingAnchor.constraint(equalTo: contentArea.leadingAnchor),
            textScrollView.trailingAnchor.constraint(equalTo: contentArea.trailingAnchor),
        ])

        containerView.addSubview(titleLabel)
        containerView.addSubview(metaLabel)
        containerView.addSubview(separatorView)
        containerView.addSubview(contentArea)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: containerView.topAnchor, constant: Theme.spacingXXL - 4),
            titleLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: Theme.spacingXXL),
            titleLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -Theme.spacingXXL),

            metaLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: Theme.spacingSM),
            metaLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: Theme.spacingXXL),
            metaLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -Theme.spacingXXL),

            separatorView.topAnchor.constraint(equalTo: metaLabel.bottomAnchor, constant: Theme.spacingLG + 4),
            separatorView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: Theme.spacingXXL),
            separatorView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -Theme.spacingXXL),
            separatorView.heightAnchor.constraint(equalToConstant: 1),

            contentArea.topAnchor.constraint(equalTo: separatorView.bottomAnchor, constant: Theme.spacingXS),
            contentArea.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
            contentArea.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            contentArea.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
        ])

        // Empty state
        emptyStateView = NSView()
        emptyStateView.translatesAutoresizingMaskIntoConstraints = false
        emptyStateView.wantsLayer = true
        emptyStateView.layer?.backgroundColor = Theme.emptyStateBackground.cgColor
        containerView.addSubview(emptyStateView)

        let iconView = NSImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyDown
        if let iconURL = Bundle.module.url(forResource: "les", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            iconView.image = icon
        }
        iconView.alphaValue = 0.12
        emptyStateView.addSubview(iconView)

        let hintLabel = NSTextField(labelWithString: "Select an item to read")
        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        hintLabel.font = .systemFont(ofSize: 14, weight: .regular)
        hintLabel.textColor = Theme.tertiaryText
        hintLabel.alignment = .center
        emptyStateView.addSubview(hintLabel)

        let shortcutLabel = NSTextField(labelWithString: "j/k to navigate  ·  ? for shortcuts")
        shortcutLabel.translatesAutoresizingMaskIntoConstraints = false
        shortcutLabel.font = .systemFont(ofSize: 11, weight: .regular)
        shortcutLabel.textColor = Theme.tertiaryText
        shortcutLabel.alphaValue = 0.6
        shortcutLabel.alignment = .center
        emptyStateView.addSubview(shortcutLabel)

        NSLayoutConstraint.activate([
            emptyStateView.topAnchor.constraint(equalTo: containerView.topAnchor),
            emptyStateView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
            emptyStateView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            emptyStateView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),

            iconView.centerXAnchor.constraint(equalTo: emptyStateView.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: emptyStateView.centerYAnchor, constant: -30),
            iconView.widthAnchor.constraint(equalToConstant: 72),
            iconView.heightAnchor.constraint(equalToConstant: 72),

            hintLabel.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: Theme.spacingLG),
            hintLabel.centerXAnchor.constraint(equalTo: emptyStateView.centerXAnchor),

            shortcutLabel.topAnchor.constraint(equalTo: hintLabel.bottomAnchor, constant: Theme.spacingXS + 2),
            shortcutLabel.centerXAnchor.constraint(equalTo: emptyStateView.centerXAnchor),
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

        // Fade out empty state, show content
        if !emptyStateView.isHidden {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.15
                emptyStateView.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                self?.emptyStateView.isHidden = true
                self?.emptyStateView.alphaValue = 1
            })
        }

        titleLabel.isHidden = false
        metaLabel.isHidden = false
        separatorView.isHidden = false

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

        if let urlStr = content.url, let url = URL(string: urlStr),
           (content.isBookmark || isThinContent(content)) {
            showWebView()
            ensureWebView().load(URLRequest(url: url))
        } else {
            showTextView()
            renderText(content: content, itemId: itemId)
        }
    }

    func clear() {
        currentRenderTask?.cancel()
        titleLabel.isHidden = true
        metaLabel.isHidden = true
        separatorView.isHidden = true
        textScrollView.isHidden = true
        webView?.isHidden = true
        textView.textStorage?.setAttributedString(NSAttributedString(string: ""))
        webView?.loadHTMLString("", baseURL: nil)
        emptyStateView.isHidden = false
        emptyStateView.alphaValue = 1
    }

    // MARK: - Lazy WKWebView

    private func ensureWebView() -> WKWebView {
        if let existing = webView { return existing }
        let config = WKWebViewConfiguration()
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.translatesAutoresizingMaskIntoConstraints = false
        wv.isHidden = true
        contentArea.addSubview(wv)
        NSLayoutConstraint.activate([
            wv.topAnchor.constraint(equalTo: contentArea.topAnchor),
            wv.bottomAnchor.constraint(equalTo: contentArea.bottomAnchor),
            wv.leadingAnchor.constraint(equalTo: contentArea.leadingAnchor),
            wv.trailingAnchor.constraint(equalTo: contentArea.trailingAnchor),
        ])
        webView = wv
        return wv
    }

    // MARK: - View switching

    private func showWebView() {
        textScrollView.isHidden = true
        ensureWebView().isHidden = false
    }

    private func showTextView() {
        webView?.isHidden = true
        textScrollView.isHidden = false
    }

    // MARK: - Text rendering (RSS)

    private func renderText(content: ItemRecord.Content, itemId: String) {
        currentRenderTask = Task { [weak self] in
            guard let self else { return }

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

    // MARK: - Content detection

    private func isThinContent(_ content: ItemRecord.Content) -> Bool {
        let html = content.contentHTML ?? content.summaryHTML ?? ""
        if html.isEmpty { return true }
        let plain = html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return plain.count < 200
    }

    // MARK: - Vim scroll

    private let scrollStep: CGFloat = 60

    func scrollDown() {
        if let wv = webView, !wv.isHidden {
            wv.evaluateJavaScript("window.scrollBy(0, 60)")
        } else {
            let clipView = textScrollView.contentView
            var origin = clipView.bounds.origin
            let maxY = (textScrollView.documentView?.frame.height ?? 0) - clipView.bounds.height
            origin.y = min(origin.y + scrollStep, max(maxY, 0))
            clipView.animator().setBoundsOrigin(origin)
        }
    }

    func scrollUp() {
        if let wv = webView, !wv.isHidden {
            wv.evaluateJavaScript("window.scrollBy(0, -60)")
        } else {
            let clipView = textScrollView.contentView
            var origin = clipView.bounds.origin
            origin.y = max(origin.y - scrollStep, 0)
            clipView.animator().setBoundsOrigin(origin)
        }
    }
}
