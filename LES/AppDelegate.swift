import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate {
    var mainWindowController: MainWindowController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            try DatabaseManager.shared.setup()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Database Error"
            alert.informativeText = "Failed to initialize database: \(error.localizedDescription)"
            alert.alertStyle = .critical
            alert.runModal()
            NSApp.terminate(nil)
            return
        }

        buildMainMenu()

        mainWindowController = MainWindowController()
        mainWindowController.showWindow(nil)
        mainWindowController.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        Task {
            await RefreshScheduler.shared.start()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }

    // MARK: - Main Menu

    private func buildMainMenu() {
        let mainMenu = NSMenu()

        // App menu
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About les", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit les", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // File menu
        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Add Feed…", action: #selector(MainWindowController.addFeed(_:)), keyEquivalent: "n")
        fileMenu.addItem(withTitle: "Add Bookmark…", action: #selector(MainWindowController.addBookmark(_:)), keyEquivalent: "b")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Import OPML…", action: #selector(MainWindowController.importOPML(_:)), keyEquivalent: "i")
        fileMenu.addItem(withTitle: "Export OPML…", action: #selector(exportOPML(_:)), keyEquivalent: "e")
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        // View menu
        let viewMenuItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        let refreshItem = NSMenuItem(title: "Refresh Feed", action: #selector(MainWindowController.refreshCurrentFeed(_:)), keyEquivalent: "r")
        refreshItem.keyEquivalentModifierMask = [.command]
        viewMenu.addItem(refreshItem)
        let refreshAllItem = NSMenuItem(title: "Refresh All", action: #selector(MainWindowController.refreshAllFeeds(_:)), keyEquivalent: "r")
        refreshAllItem.keyEquivalentModifierMask = [.command, .shift]
        viewMenu.addItem(refreshAllItem)
        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

        // Window menu
        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }

    @IBAction func exportOPML(_ sender: Any?) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "les-feeds.opml"
        panel.allowedContentTypes = [.xml]

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let feedStore = FeedStore(db: DatabaseManager.shared.dbPool)
                let feeds = try feedStore.allFeedsForRefresh()
                let data = OPMLParser.export(feeds: feeds)
                try data.write(to: url)
            } catch {
                let alert = NSAlert(error: error)
                alert.runModal()
            }
        }
    }
}
