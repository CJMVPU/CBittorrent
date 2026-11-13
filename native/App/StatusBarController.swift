import AppKit

/// Kept alive by the application delegate, independently of the main window.
@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let store: AppStore
    private let showWindow: () -> Void
    private let showSettings: () -> Void
    private let summary = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let rates = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var resumeItem: NSMenuItem!
    private var pauseItem: NSMenuItem!

    init(store: AppStore, showWindow: @escaping () -> Void, showSettings: @escaping () -> Void) {
        self.store = store
        self.showWindow = showWindow
        self.showSettings = showSettings
        super.init()
        // The shared artwork template adapts to light/dark menu bars without a white tile.
        item.button?.title = ""
        item.button?.image = BrandMark.menuImage()
        item.button?.imagePosition = .imageOnly
        item.button?.setAccessibilityLabel("CBittorrent 菜单栏")
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        summary.isEnabled = false
        rates.isEnabled = false
        menu.addItem(summary)
        menu.addItem(rates)
        menu.addItem(.separator())
        add("打开 CBittorrent", action: #selector(openWindow), to: menu)
        add("设置…", action: #selector(openSettings), to: menu)
        menu.addItem(.separator())
        resumeItem = add("开始全部任务", action: #selector(resumeAll), to: menu)
        pauseItem = add("暂停全部任务", action: #selector(pauseAll), to: menu)
        menu.addItem(.separator())
        add("退出 CBittorrent", action: #selector(quit), to: menu)
        item.menu = menu
        store.onStatusChange = { [weak self] in self?.refresh() }
        refresh()
    }

    @discardableResult
    private func add(_ title: String, action: Selector, to menu: NSMenu) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
        entry.target = self
        menu.addItem(entry)
        return entry
    }

    func refresh() {
        let snapshot = store.snapshot
        let downloading = snapshot.torrents.filter { TaskFilter.downloading.matches($0) }.count
        let seeding = snapshot.torrents.filter { TaskFilter.seeding.matches($0) }.count
        summary.title = "\(snapshot.torrents.count) 个任务 · \(downloading) 下载 · \(seeding) 做种"
        rates.title = "↓ \(Titanium.bytes(snapshot.downloadRate))/s   ↑ \(Titanium.bytes(snapshot.uploadRate))/s"
        item.button?.toolTip = "CBittorrent\n\(summary.title)\n\(rates.title)"
        resumeItem.isEnabled = !snapshot.torrents.isEmpty
        pauseItem.isEnabled = !snapshot.torrents.isEmpty
    }

    func menuWillOpen(_ menu: NSMenu) { refresh() }
    @objc private func openWindow() { showWindow() }
    @objc private func openSettings() { showSettings() }
    @objc private func resumeAll() { store.startAll() }
    @objc private func pauseAll() { store.pauseAll() }
    @objc private func quit() { NSApp.terminate(nil) }
}
