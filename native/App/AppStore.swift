import AppKit
import UniformTypeIdentifiers
import UserNotifications

@MainActor
final class AppStore {
    private(set) var snapshot = EngineSnapshot()
    var selectedIDs = Set<String>()
    var filter: TaskFilter = .all
    var searchText = ""
    private(set) var settings: AppSettings
    var onChange: (() -> Void)?
    private let engine: EngineService
    private let settingsURL: URL
    private var polling: Task<Void, Never>?
    private var shownErrors = Set<String>()
    private var stopping = false

    init(profile: URL) throws {
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        settingsURL = profile.appendingPathComponent("settings.json")
        if FileManager.default.fileExists(atPath: settingsURL.path) {
            settings = try JSONDecoder().decode(AppSettings.self, from: Data(contentsOf: settingsURL))
        } else { settings = AppSettings() }
        engine = try EngineService(profilePath: profile.appendingPathComponent("Session").path)
    }

    var filteredTorrents: [TorrentSnapshot] {
        snapshot.torrents.filter { filter.matches($0) && (searchText.isEmpty || $0.name.localizedCaseInsensitiveContains(searchText)) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    var selectedTorrent: TorrentSnapshot? { snapshot.torrents.first { selectedIDs.contains($0.id) } }
    func select(ids: Set<String>) { selectedIDs = ids; onChange?() }
    func setFilter(_ value: TaskFilter) { filter = value; onChange?() }
    func setSearch(_ value: String) { searchText = value; onChange?() }

    func start() {
        polling = Task { [weak self] in
            guard let self else { return }
            do { try await self.applyLimits(self.settings) } catch { self.present(error) }
            var tick = 0
            while !Task.isCancelled && !self.stopping {
                await self.refresh()
                tick += 1
                if tick % 30 == 0 {
                    do { try await self.engine.save() } catch { self.presentOnce(error.localizedDescription) }
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func refresh() async {
        do {
            let next = try await engine.snapshot()
            if settings.notifyOnCompletion {
                for torrent in next.torrents where torrent.progress >= 1 {
                    if let old = snapshot.torrents.first(where: { $0.id == torrent.id }), old.progress < 1 {
                        let content = UNMutableNotificationContent()
                        content.title = "下载完成"
                        content.body = torrent.name
                        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: torrent.id, content: content, trigger: nil))
                    }
                }
            }
            snapshot = next
            selectedIDs.formIntersection(Set(next.torrents.map(\.id)))
            onChange?()
            for error in next.errors { presentOnce(error) }
        } catch { if !stopping { presentOnce(error.localizedDescription) } }
    }

    private func run(_ operation: @escaping () async throws -> Void) {
        guard !stopping else { return }
        Task {
            do { try await operation(); try await engine.save(); await refresh() }
            catch { present(error) }
        }
    }

    func add(sources: [String]) {
        let destination = settings.downloadPath
        let paused = settings.addPaused
        run { [self] in
            try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)
            for source in sources { try await engine.add(source: source, savePath: destination, paused: paused) }
        }
    }

    func addTorrentPrompt() {
        let alert = NSAlert()
        alert.messageText = "添加下载任务"
        alert.informativeText = "粘贴磁力链接，或选择 .torrent 文件。下载位置：\(settings.downloadPath)"
        alert.addButton(withTitle: "添加磁力链接")
        alert.addButton(withTitle: "选择种子文件…")
        alert.addButton(withTitle: "取消")
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 430, height: 26))
        input.placeholderString = "magnet:?xt=urn:btih:…"
        alert.accessoryView = input
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let source = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard source.lowercased().hasPrefix("magnet:?") else { present(ClientError.message("请输入有效的 magnet 磁力链接。")); return }
            add(sources: ["magnet:" + source.dropFirst(7)])
        } else if response == .alertSecondButtonReturn {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [UTType(filenameExtension: "torrent") ?? .data]
            panel.allowsMultipleSelection = true
            panel.canChooseDirectories = false
            if panel.runModal() == .OK { add(sources: panel.urls.map(\.path)) }
        }
    }

    func startSelected() {
        let ids = selectedIDs
        run { [self] in for id in ids { try await engine.resume(id: id) } }
    }
    func pauseSelected() {
        let ids = selectedIDs
        run { [self] in for id in ids { try await engine.pause(id: id) } }
    }
    func removeSelected() {
        let ids = selectedIDs
        guard !ids.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "移除 \(ids.count) 个下载任务？"
        alert.informativeText = "默认保留已下载的文件。"
        alert.addButton(withTitle: "移除任务")
        alert.addButton(withTitle: "取消")
        let checkbox = NSButton(checkboxWithTitle: "同时永久删除下载文件", target: nil, action: nil)
        checkbox.setFrameSize(NSSize(width: 320, height: 24))
        alert.accessoryView = checkbox
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let deleteFiles = checkbox.state == .on
        run { [self] in for id in ids { try await engine.remove(id: id, deleteFiles: deleteFiles) } }
    }
    func revealSelected() {
        guard let torrent = selectedTorrent else { return }
        let url = URL(fileURLWithPath: torrent.savePath)
        NSWorkspace.shared.open(url)
    }

    private func applyLimits(_ value: AppSettings) async throws {
        let maximum = Int(Int32.max) / 1024
        guard (0...maximum).contains(value.downloadLimitKB), (0...maximum).contains(value.uploadLimitKB) else {
            throw ClientError.message("速度限制必须在 0 至 \(maximum) KiB/s 之间，0 表示不限速。")
        }
        try await engine.setLimits(download: value.downloadLimitKB * 1024, upload: value.uploadLimitKB * 1024)
    }
    func updateSettings(_ value: AppSettings, completion: ((Bool) -> Void)? = nil) {
        guard !stopping else { completion?(false); return }
        Task { [self] in
          do {
            guard value.downloadPath.hasPrefix("/") else { throw ClientError.message("请选择绝对路径作为下载目录。") }
            try FileManager.default.createDirectory(atPath: value.downloadPath, withIntermediateDirectories: true)
            try await applyLimits(value)
            do { try JSONEncoder().encode(value).write(to: settingsURL, options: .atomic) }
            catch { try? await applyLimits(settings); throw error }
            let requestNotifications = value.notifyOnCompletion && !settings.notifyOnCompletion
            settings = value
            onChange?()
            if requestNotifications { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) }
            completion?(true)
          } catch { completion?(false); present(error) }
        }
    }

    func showFiles() {
        guard let torrent = selectedTorrent else { return }
        let alert = NSAlert()
        alert.messageText = "任务文件 · \(torrent.name)"
        alert.informativeText = torrent.files.isEmpty ? "正在获取元数据。" : "选择文件并设置优先级；跳过的文件不会继续下载。"
        alert.addButton(withTitle: "完成")
        if !torrent.files.isEmpty { alert.addButton(withTitle: "应用优先级") }
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 220))
        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 182, width: 520, height: 26))
        picker.addItems(withTitles: torrent.files.map { $0.path })
        let priority = NSPopUpButton(frame: NSRect(x: 0, y: 146, width: 200, height: 26))
        priority.addItems(withTitles: ["跳过", "低", "正常", "高"])
        priority.selectItem(at: 2)
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 130))
        text.isEditable = false
        text.string = torrent.files.map { "\(Int($0.progress * 100))%  \(ByteCountFormatter.string(fromByteCount: $0.size, countStyle: .file))  \($0.path)" }.joined(separator: "\n")
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 520, height: 135))
        scroll.hasVerticalScroller = true; scroll.documentView = text
        container.addSubview(scroll); container.addSubview(picker); container.addSubview(priority)
        alert.accessoryView = container
        if alert.runModal() == .alertSecondButtonReturn, picker.indexOfSelectedItem >= 0 {
            let file = torrent.files[picker.indexOfSelectedItem]
            let value = [0, 1, 4, 7][priority.indexOfSelectedItem]
            run { [self] in try await engine.setFilePriority(id: torrent.id, index: file.index, priority: value) }
        }
    }
    func showTrackers() {
        guard let torrent = selectedTorrent else { return }
        let alert = NSAlert()
        alert.messageText = "Tracker · \(torrent.name)"
        alert.informativeText = torrent.trackers.isEmpty ? "暂无 Tracker。" : torrent.trackers.map { "\($0.url)\n\($0.status)" }.joined(separator: "\n\n")
        alert.runModal()
    }
    func present(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "CBittorrent"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }
    private func presentOnce(_ text: String) {
        guard shownErrors.insert(text).inserted else { return }
        present(ClientError.message(text))
    }
    func shutdown() async throws {
        stopping = true
        polling?.cancel()
        do { try await engine.close() }
        catch { stopping = false; start(); throw error }
    }
}
