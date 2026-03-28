import Cocoa

/// Centralized design tokens for les
enum Theme {
    // MARK: - Accent Colors

    static let accent = NSColor(name: "accent") { appearance in
        appearance.isDark
            ? NSColor(calibratedRed: 0.78, green: 0.58, blue: 0.36, alpha: 1.0)
            : NSColor(calibratedRed: 0.545, green: 0.341, blue: 0.165, alpha: 1.0)
    }

    static let accentSubtle = NSColor(name: "accentSubtle") { appearance in
        appearance.isDark
            ? NSColor(calibratedRed: 0.78, green: 0.58, blue: 0.36, alpha: 0.5)
            : NSColor(calibratedRed: 0.545, green: 0.341, blue: 0.165, alpha: 0.7)
    }

    // MARK: - Backgrounds

    static let readerBackground = NSColor(name: "readerBg") { appearance in
        appearance.isDark
            ? NSColor(calibratedRed: 0.13, green: 0.13, blue: 0.13, alpha: 1.0)
            : NSColor(calibratedRed: 0.988, green: 0.984, blue: 0.976, alpha: 1.0)
    }

    static let emptyStateBackground = NSColor(name: "emptyBg") { appearance in
        appearance.isDark
            ? NSColor(calibratedRed: 0.11, green: 0.11, blue: 0.11, alpha: 1.0)
            : NSColor(calibratedRed: 0.85, green: 0.83, blue: 0.80, alpha: 1.0)
    }

    static let codeBackground = NSColor(name: "codeBg") { appearance in
        appearance.isDark
            ? NSColor(calibratedWhite: 1.0, alpha: 0.06)
            : NSColor(calibratedWhite: 0.0, alpha: 0.04)
    }

    static let codeBlockBackground = NSColor(name: "codeBlockBg") { appearance in
        appearance.isDark
            ? NSColor(calibratedRed: 0.16, green: 0.16, blue: 0.15, alpha: 1.0)
            : NSColor(calibratedRed: 0.973, green: 0.969, blue: 0.961, alpha: 1.0)
    }

    // MARK: - Text Colors

    static let primaryText = NSColor(name: "primaryText") { appearance in
        appearance.isDark
            ? NSColor(calibratedWhite: 0.90, alpha: 1.0)
            : NSColor(calibratedWhite: 0.11, alpha: 1.0)
    }

    static let secondaryText = NSColor(name: "secondaryText") { appearance in
        appearance.isDark
            ? NSColor(calibratedWhite: 0.55, alpha: 1.0)
            : NSColor(calibratedWhite: 0.45, alpha: 1.0)
    }

    static let tertiaryText = NSColor(name: "tertiaryText") { appearance in
        appearance.isDark
            ? NSColor(calibratedWhite: 0.40, alpha: 1.0)
            : NSColor(calibratedWhite: 0.55, alpha: 1.0)
    }

    // MARK: - Separators

    static let separator = NSColor(name: "separator") { appearance in
        appearance.isDark
            ? NSColor(calibratedWhite: 1.0, alpha: 0.08)
            : NSColor(calibratedWhite: 0.0, alpha: 0.06)
    }

    // MARK: - Spacing (consistent 4px grid)

    static let spacingXS: CGFloat = 4
    static let spacingSM: CGFloat = 8
    static let spacingMD: CGFloat = 12
    static let spacingLG: CGFloat = 16
    static let spacingXL: CGFloat = 24
    static let spacingXXL: CGFloat = 32

    // MARK: - Corner Radii

    static let radiusSM: CGFloat = 4
    static let radiusMD: CGFloat = 6
    static let radiusLG: CGFloat = 8
    static let radiusXL: CGFloat = 10

    // MARK: - Row Heights

    static let sidebarRowHeight: CGFloat = 28
    static let sidebarDividerHeight: CGFloat = 25
    static let itemRowHeight: CGFloat = 52

    // MARK: - Fonts

    static let sidebarFont = NSFont.systemFont(ofSize: 13, weight: .regular)
    static let sidebarFontBold = NSFont.systemFont(ofSize: 13, weight: .medium)
    static let sidebarSectionFont = NSFont.systemFont(ofSize: 10, weight: .semibold)
    static let itemTitleFont = NSFont.systemFont(ofSize: 13, weight: .regular)
    static let itemTitleFontBold = NSFont.systemFont(ofSize: 13, weight: .medium)
    static let itemDetailFont = NSFont.systemFont(ofSize: 11, weight: .regular)
    static let badgeFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
    static let readerTitleFont = NSFont.systemFont(ofSize: 24, weight: .bold)
    static let readerMetaFont = NSFont.systemFont(ofSize: 12, weight: .regular)

    // MARK: - Reader HTML CSS

    static func readerCSS(isDark: Bool) -> String {
        let textColor = isDark ? "#E5E5E5" : "#2C2C2E"
        let headingColor = isDark ? "#F0F0F0" : "#1C1C1E"
        let linkColor = isDark ? "#C89458" : "#8B572A"
        let linkBorderAlpha = isDark ? "0.35" : "0.25"
        let codeBg = isDark ? "rgba(255,255,255,0.06)" : "rgba(0,0,0,0.04)"
        let codeText = isDark ? "#C8C8CA" : "#3C3C3E"
        let preBackground = isDark ? "#282826" : "#F8F7F5"
        let preBorder = isDark ? "rgba(255,255,255,0.08)" : "rgba(0,0,0,0.06)"
        let blockquoteBorder = isDark ? "#8B7355" : "#C4A882"
        let blockquoteText = isDark ? "#9A9A9E" : "#636366"
        let hrBorder = isDark ? "rgba(255,255,255,0.1)" : "rgba(0,0,0,0.08)"
        let strongColor = isDark ? "#F0F0F0" : "#1C1C1E"
        let figcaptionColor = isDark ? "#777" : "#888"

        return """
        body {
            font-family: "New York", "Iowan Old Style", Georgia, serif;
            font-size: 16.5px;
            line-height: 1.75;
            color: \(textColor);
            max-width: 640px;
            -webkit-font-smoothing: antialiased;
        }
        p { margin-bottom: 1.1em; }
        h1, h2, h3, h4 {
            font-family: -apple-system, "SF Pro Display", "Helvetica Neue", sans-serif;
            font-weight: 700;
            color: \(headingColor);
            letter-spacing: -0.02em;
            line-height: 1.25;
            margin-top: 1.8em;
            margin-bottom: 0.6em;
        }
        h1 { font-size: 26px; }
        h2 { font-size: 22px; }
        h3 { font-size: 18px; }
        a {
            color: \(linkColor);
            text-decoration: none;
            border-bottom: 1px solid rgba(\(isDark ? "200,148,88" : "139,87,42"), \(linkBorderAlpha));
        }
        pre, code {
            font-family: "SF Mono", "Menlo", "Monaco", monospace;
            font-size: 14px;
        }
        code {
            background-color: \(codeBg);
            padding: 2px 5px;
            border-radius: 6px;
            color: \(codeText);
        }
        pre {
            background-color: \(preBackground);
            padding: 16px 20px;
            border-radius: 10px;
            overflow-x: auto;
            border: 1px solid \(preBorder);
            line-height: 1.5;
        }
        pre code { background: none; padding: 0; border-radius: 0; }
        blockquote {
            margin: 1.4em 0;
            margin-left: 0;
            padding: 0 0 0 20px;
            border-left: 2px solid \(blockquoteBorder);
            color: \(blockquoteText);
            font-style: italic;
        }
        ul, ol { padding-left: 1.6em; margin-bottom: 1.1em; }
        li { margin-bottom: 0.4em; }
        hr { border: none; border-top: 1px solid \(hrBorder); margin: 2em 0; }
        strong { font-weight: 600; color: \(strongColor); }
        img {
            max-width: 100%;
            height: auto;
            border-radius: 8px;
            margin: 0.8em 0;
            display: block;
        }
        figure { margin: 1.2em 0; padding: 0; }
        figcaption {
            font-size: 13px;
            color: \(figcaptionColor);
            margin-top: 6px;
            text-align: center;
        }
        """
    }
}

// MARK: - NSAppearance Helper

extension NSAppearance {
    var isDark: Bool {
        bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
}
