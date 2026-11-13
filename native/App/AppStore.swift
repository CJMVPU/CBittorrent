import AppKit
import UserNotifications

@MainActor
final class AppStore {
    private(set) var snapshot = EngineSnapshot()
    var selectedIDs = Set<String>()
    var filter: TaskFilter = .all
    var searchText = ""
    private(set) var settings: AppSettings
    var onChange: (() -> Void)?
    var onStatusChange: (() -> Void)?
    var onPresent: ((InWindowRequest) -> Void)?
    private let engine: EngineService
    private let settingsURL: URL
    private var polling: Task<Void, Never>?
    private var shownErrors = Set<String>()
    private var stopping = false
    private var savingSettings = false

    init(profile: URL) throws {
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        settingsURL = profile.appendingPathComponent("settings.json")
        if FileManager.default.fileExists(atPath: settingsURL.path) {
            settings = try JSONDecoder().decode(AppSettings.self, from: Data(contentsOf: settingsURL))
        } else { settings = AppSettings() }
        settings = try settings.validated()
        engine = try EngineService(profilePath: profile.appendingPathComponent("Session").path, settings: settings)
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
            onStatusChange?()
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
        addFromForm(sources: sources) { [weak self] _, error in
            if let error { self?.present(ClientError.message(error)) }
        }
    }

    /// Reports accepted sources so a partially successful batch is not submitted twice.
    func addFromForm(sources: [String], completion: @escaping ([String], String?) -> Void) {
        guard !stopping else { completion([], "下载引擎正在关闭。"); return }
        let destination = settings.downloadPath
        let paused = settings.addPaused
        Task {
            var accepted: [String] = []
            var failure: String?
            do {
                try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)
                for source in sources {
                    try await engine.add(source: source, savePath: destination, paused: paused)
                    accepted.append(source)
                }
            } catch { failure = error.localizedDescription }
            do { try await engine.save() }
            catch { failure = [failure, "任务保存失败：\(error.localizedDescription)"].compactMap { $0 }.joined(separator: "\n") }
            await refresh()
            completion(accepted, failure)
        }
    }

    func addTorrentPrompt() { onPresent?(.add) }

    func chooseDirectory(initial: URL, onSelect: @escaping (URL) -> Void) {
        onPresent?(.chooseDirectory(initial: initial, onSelect: onSelect))
    }

    func startSelected() {
        let ids = selectedIDs
        run { [self] in for id in ids { try await engine.resume(id: id) } }
    }
    func pauseSelected() {
        let ids = selectedIDs
        run { [self] in for id in ids { try await engine.pause(id: id) } }
    }
    func startAll() {
        let ids = snapshot.torrents.map(\.id)
        run { [self] in for id in ids { try await engine.resume(id: id) } }
    }
    func pauseAll() {
        let ids = snapshot.torrents.map(\.id)
        run { [self] in for id in ids { try await engine.pause(id: id) } }
    }
    func applyDefaultTrackers(completion: @escaping (Int?) -> Void) {
        guard !stopping, !savingSettings else { completion(nil); return }
        Task {
            do {
                let changed = try await engine.applyDefaultTrackers()
                try await engine.save()
                await refresh()
                completion(changed)
            } catch { completion(nil); present(error) }
        }
    }
    func removeSelected() {
        guard !selectedIDs.isEmpty else { return }
        onPresent?(.remove(ids: selectedIDs))
    }

    func confirmedRemove(ids: Set<String>, deleteFiles: Bool, completion: @escaping (String?) -> Void) {
        guard !stopping else { completion("下载引擎正在关闭。"); return }
        let existing = ids.intersection(Set(snapshot.torrents.map(\.id)))
        Task {
            var failure: String?
            do {
                for id in existing { try await engine.remove(id: id, deleteFiles: deleteFiles) }
                try await engine.save()
            } catch { failure = error.localizedDescription }
            await refresh()
            completion(failure)
        }
    }

    func applyFilePriority(id: String, index: Int, priority: Int, completion: @escaping (String?) -> Void) {
        guard !stopping else { completion("下载引擎正在关闭。"); return }
        Task {
            do {
                try await engine.setFilePriority(id: id, index: index, priority: priority)
                try await engine.save()
                await refresh()
                completion(nil)
            } catch { completion(error.localizedDescription) }
        }
    }
    func revealSelected() {
        guard let torrent = selectedTorrent else { return }
        let url = URL(fileURLWithPath: torrent.savePath)
        onPresent?(.browseLocation(url))
    }

    func updateSettings(_ value: AppSettings, completion: ((Bool) -> Void)? = nil) {
        guard !stopping, !savingSettings else { completion?(false); return }
        savingSettings = true
        Task { [self] in
            defer { savingSettings = false }
            do {
                let next = try value.validated()
                let previous = settings
                let encoded = try JSONEncoder().encode(next)
                try FileManager.default.createDirectory(atPath: next.downloadPath, withIntermediateDirectories: true)
                try await engine.applySettings(next)
                do {
                    try encoded.write(to: settingsURL, options: .atomic)
                } catch {
                    let persistenceError = error
                    do { try await engine.applySettings(previous) }
                    catch {
                        settings = next
                        onChange?()
                        throw ClientError.message("设置未能写入磁盘，且无法恢复之前的引擎配置。当前运行配置已改变，请重试保存。\n\(persistenceError.localizedDescription)\n\(error.localizedDescription)")
                    }
                    throw persistenceError
                }
                let requestNotifications = next.notifyOnCompletion && !previous.notifyOnCompletion
                settings = next
                onChange?()
                if requestNotifications {
                    _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                }
                completion?(true)
            } catch { completion?(false); present(error) }
        }
    }

    func showFiles() {
        guard let torrent = selectedTorrent else { return }
        onPresent?(.files(torrent))
    }
    func showTrackers() {
        guard let torrent = selectedTorrent else { return }
        onPresent?(.trackers(torrent))
    }
    func present(_ error: Error) {
        onPresent?(.message(title: "CBittorrent", body: error.localizedDescription))
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
