import AppKit
import UserNotifications

@MainActor
final class AppStore {
    private(set) var snapshot = EngineSnapshot()
    private(set) var selectedIDs = Set<String>()
    private(set) var filter: TaskFilter = .all
    private(set) var searchText = ""
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

    private(set) var filteredTorrents: [TorrentSnapshot] = []
    var selectedTorrent: TorrentSnapshot? { filteredTorrents.first { selectedIDs.contains($0.id) } }

    private func reconcileSelection() {
        filteredTorrents = TransferSelection.visible(torrents: snapshot.torrents, filter: filter, search: searchText)
        selectedIDs = TransferSelection.reconcile(selectedIDs, visible: filteredTorrents)
    }
    func select(ids: Set<String>) {
        selectedIDs = TransferSelection.reconcile(ids, visible: filteredTorrents)
        onChange?()
    }
    func setFilter(_ value: TaskFilter) { filter = value; reconcileSelection(); onChange?() }
    func setSearch(_ value: String) { searchText = value; reconcileSelection(); onChange?() }

    func start() {
        polling = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled && !self.stopping {
                await self.refresh()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func refresh() async {
        do {
            var next = try await engine.snapshot()
            next.summary = TransferSummary(torrents: next.torrents)
            let previous = Dictionary(uniqueKeysWithValues: snapshot.torrents.map { ($0.id, $0) })
            if settings.notifyOnCompletion {
                for torrent in next.torrents where torrent.progress >= 1 {
                    if let old = previous[torrent.id], old.progress < 1 {
                        let content = UNMutableNotificationContent()
                        content.title = "下载完成"
                        content.body = torrent.name
                        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: torrent.id, content: content, trigger: nil))
                    }
                }
            }
            snapshot = next
            onStatusChange?()
            reconcileSelection()
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
                let previousData = try JSONEncoder().encode(previous)
                try await SettingsTransaction.commit {
                    try encoded.write(to: settingsURL, options: .atomic)
                } apply: {
                    try await engine.applySettings(next)
                } rollback: {
                    // Restore persisted preferences even if restoring the engine fails.
                    try previousData.write(to: settingsURL, options: .atomic)
                    try await engine.applySettings(previous)
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

    func refreshDetail(id: String, completion: @escaping (TorrentSnapshot?, String?) -> Void) {
        guard !stopping else { completion(nil, "下载引擎正在关闭。"); return }
        Task {
            do { completion(try await engine.detail(id: id), nil) }
            catch { completion(nil, error.localizedDescription) }
        }
    }
    func showFiles() {
        guard let torrent = selectedTorrent else { return }
        refreshDetail(id: torrent.id) { [weak self] detail, error in
            if let detail { self?.onPresent?(.files(detail)) }
            else if let error { self?.present(ClientError.message(error)) }
        }
    }
    func showTrackers() {
        guard let torrent = selectedTorrent else { return }
        refreshDetail(id: torrent.id) { [weak self] detail, error in
            if let detail { self?.onPresent?(.trackers(detail)) }
            else if let error { self?.present(ClientError.message(error)) }
        }
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
