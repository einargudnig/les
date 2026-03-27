import Cocoa

class ReaderViewController: NSViewController {
    private(set) var textView: NSTextView!
    private var scrollView: NSScrollView!
    private var headerStack: NSStackView!
    private var titleLabel: NSTextField!
    private var metaLabel: NSTextField!
    private var separatorView: NSView!
    private var containerView: NSView!

    private var currentRenderTask: Task<Void, Never>?
    private let renderer = ReaderRenderer()

    // Warm paper background
    private let readerBackground = NSColor(calibratedRed: 0.988, green: 0.984, blue: 0.976, alpha: 1.0)
    private let accentColor = NSColor(calibratedRed: 0.545, green: 0.341, blue: 0.165, alpha: 1.0) // warm brown

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

        // Text view for content
        scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = true
        scrollView.backgroundColor = readerBackground

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

        scrollView.documentView = textView

        containerView.addSubview(titleLabel)
        containerView.addSubview(metaLabel)
        containerView.addSubview(separatorView)
        containerView.addSubview(scrollView)

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

            scrollView.topAnchor.constraint(equalTo: separatorView.bottomAnchor, constant: 4),
            scrollView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
        ])

        self.view = containerView
    }

    func showItem(itemId: String) {
        // Cancel previous render
        currentRenderTask?.cancel()

        // Show title/meta immediately
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
        metaLabel.stringValue = meta.joined(separator: "  ·  ")

        separatorView.isHidden = false

        // Async render content
        currentRenderTask = Task { [weak self] in
            guard let self else { return }

            // Check cache first
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

            // Render from HTML
            let html = content.contentHTML ?? content.summaryHTML ?? ""
            let attrStr = await renderer.render(html: html)

            guard !Task.isCancelled else { return }

            // Cache it
            if let data = try? NSKeyedArchiver.archivedData(withRootObject: attrStr, requiringSecureCoding: false) {
                try? cacheStore.store(itemId: itemId, renderedData: data)
            }

            await MainActor.run {
                self.textView.textStorage?.setAttributedString(attrStr)
                self.textView.scrollToBeginningOfDocument(nil)
            }
        }
    }

    func clear() {
        currentRenderTask?.cancel()
        titleLabel.stringValue = ""
        metaLabel.stringValue = ""
        separatorView.isHidden = true
        textView.textStorage?.setAttributedString(NSAttributedString(string: ""))
    }

    // MARK: - Vim scroll

    private let scrollStep: CGFloat = 60

    func scrollDown() {
        let clipView = scrollView.contentView
        var origin = clipView.bounds.origin
        let maxY = (scrollView.documentView?.frame.height ?? 0) - clipView.bounds.height
        origin.y = min(origin.y + scrollStep, max(maxY, 0))
        clipView.animator().setBoundsOrigin(origin)
    }

    func scrollUp() {
        let clipView = scrollView.contentView
        var origin = clipView.bounds.origin
        origin.y = max(origin.y - scrollStep, 0)
        clipView.animator().setBoundsOrigin(origin)
    }
}
