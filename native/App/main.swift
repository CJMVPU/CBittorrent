import AppKit
import CoreText
import Darwin

@MainActor
final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    private var store: AppStore?
    private var controller: MainWindowController?
    private var statusBar: StatusBarController?
    private var startupController: StartupFailureController?
    private var lockDescriptor: Int32 = -1
    private var pendingSources: [String] = []
    private var terminating = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            if let font = Bundle.main.url(forResource: "LXGWWenKaiMono-Medium", withExtension: "ttf", subdirectory: "Fonts") {
                CTFontManagerRegisterFontsForURL(font as CFURL, .process, nil)
            }
            let arguments = CommandLine.arguments
            let profile: URL
            if let index = arguments.firstIndex(of: "--profile"), arguments.indices.contains(index + 1) {
                profile = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
            } else {
                profile = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("CBittorrent", isDirectory: true)
            }
            try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
            lockDescriptor = open(profile.appendingPathComponent("session.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
            guard lockDescriptor >= 0, flock(lockDescriptor, LOCK_EX | LOCK_NB) == 0 else {
                throw ClientError.message("此配置目录已被另一个 CBittorrent 实例使用，或无法写入。")
            }
            let store = try AppStore(profile: profile)
            self.store = store
            controller = MainWindowController(store: store)
            statusBar = StatusBarController(store: store,
                showWindow: { [weak self] in self?.transfers() },
                showSettings: { [weak self] in self?.settings() })
            configureMenus()
            controller?.showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)
            store.start()
            if !pendingSources.isEmpty { store.add(sources: pendingSources); pendingSources.removeAll() }
        } catch {
            startupController = StartupFailureController(error: error)
            configureMenus()
            startupController?.showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func configureMenus() {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        menu.addItem(appItem)
        let appMenu = NSMenu(title: "CBittorrent")
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "关于 CBittorrent", action: #selector(about), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "设置…", action: #selector(settings), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏 CBittorrent", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "退出 CBittorrent", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let fileItem = NSMenuItem()
        menu.addItem(fileItem)
        let fileMenu = NSMenu(title: "文件")
        fileItem.submenu = fileMenu
        fileMenu.addItem(withTitle: "添加任务…", action: #selector(add), keyEquivalent: "o")
        fileMenu.addItem(withTitle: "显示传输", action: #selector(transfers), keyEquivalent: "1")
        let editItem = NSMenuItem()
        menu.addItem(editItem)
        let edit = NSMenu(title: "编辑")
        editItem.submenu = edit
        edit.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        for item in appMenu.items + fileMenu.items where [#selector(settings), #selector(add), #selector(transfers), #selector(about)].contains(item.action) { item.target = self }
        NSApp.mainMenu = menu
    }
    @objc private func add() { store?.addTorrentPrompt() }
    private func revealWindow() {
        NSApp.unhide(nil)
        let activeController: NSWindowController? = controller ?? startupController
        activeController?.window?.deminiaturize(nil)
        activeController?.showWindow(nil)
        activeController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc private func settings() { controller?.showSettings(); revealWindow() }
    @objc private func transfers() { controller?.showTransfers(); revealWindow() }
    @objc private func about() {
        controller?.present(.about)
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        let sources = urls.compactMap { url -> String? in
            if url.scheme?.lowercased() == "magnet" { return url.absoluteString }
            if url.isFileURL && url.pathExtension.lowercased() == "torrent" { return url.path }
            return nil
        }
        if let store { store.add(sources: sources); revealWindow() }
        else { pendingSources += sources }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        revealWindow()
        return true
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let store else { return .terminateNow }
        guard !terminating else { return .terminateCancel }
        terminating = true
        Task {
            do {
                try await store.shutdown()
                if lockDescriptor >= 0 { close(lockDescriptor); lockDescriptor = -1 }
                sender.reply(toApplicationShouldTerminate: true)
            } catch {
                terminating = false
                store.present(ClientError.message("退出前保存失败，应用继续运行以保留任务。请修复磁盘问题后再次退出。\n\(error.localizedDescription)"))
                sender.reply(toApplicationShouldTerminate: false)
            }
        }
        return .terminateLater
    }
}

MainActor.assumeIsolated {
    let application = NSApplication.shared
    application.setActivationPolicy(.regular)
    let delegate = ApplicationDelegate()
    application.delegate = delegate
    withExtendedLifetime(delegate) { application.run() }
}
