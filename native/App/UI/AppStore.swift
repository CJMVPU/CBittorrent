import Foundation

@MainActor
final class AppStore {
    private(set) var snapshot = EngineSnapshot()
    private(set) var selectedIDs = Set<String>()
    private(set) var filter: TaskFilter = .all
    private(set) var searchText = ""
    var settings: AppSettings { application.settings }
    var onChange: (() -> Void)?
    var onStatusChange: (() -> Void)?
    var onPresent: ((InWindowRequest) -> Void)?
    private let application: TransferApplication
    private var polling: Task<Void, Never>?
    private var shownErrors = Set<String>()
    private var stopping = false
    private var savingSettings = false

    init(application: TransferApplication) {
        self.application = application
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
        guard polling == nil else { return }
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
            let next = try await application.snapshot()
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
            do { try await operation(); await refresh() }
            catch { await refresh(); present(error) }
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
        Task {
            do {
                let result = try await application.add(sources: sources)
                await refresh()
                completion(result.accepted, result.failure)
            } catch { completion([], error.localizedDescription) }
        }
    }

    func addTorrentPrompt() { onPresent?(.add) }

    func chooseDirectory(initial: URL, onSelect: @escaping (URL) -> Void) {
        onPresent?(.chooseDirectory(initial: initial, onSelect: onSelect))
    }

    func startSelected() {
        let ids = selectedIDs
        run { [self] in try await application.execute(.resume(Array(ids).sorted())) }
    }
    func pauseSelected() {
        let ids = selectedIDs
        run { [self] in try await application.execute(.pause(Array(ids).sorted())) }
    }
    func startAll() {
        let ids = snapshot.torrents.map(\.id)
        run { [self] in try await application.execute(.resume(Array(ids).sorted())) }
    }
    func pauseAll() {
        let ids = snapshot.torrents.map(\.id)
        run { [self] in try await application.execute(.pause(Array(ids).sorted())) }
    }
    func applyDefaultTrackers(completion: @escaping (Int?) -> Void) {
        guard !stopping, !savingSettings else { completion(nil); return }
        Task {
            do {
                let changed = try await application.applyDefaultTrackers()
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
                try await application.execute(.remove(existing.sorted(), deleteFiles: deleteFiles))
            } catch { failure = error.localizedDescription }
            await refresh()
            completion(failure)
        }
    }

    func applyFilePriority(id: String, index: Int, priority: Int, completion: @escaping (String?) -> Void) {
        guard !stopping else { completion("下载引擎正在关闭。"); return }
        Task {
            do {
                try await application.execute(.priority(id: id, index: index, priority: priority))
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
                try await application.updateSettings(value)
                onChange?()
                completion?(true)
            } catch { completion?(false); present(error) }
        }
    }

    func refreshDetail(id: String, completion: @escaping (TorrentSnapshot?, String?) -> Void) {
        guard !stopping else { completion(nil, "下载引擎正在关闭。"); return }
        Task {
            do { completion(try await application.detail(id: id), nil) }
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
    func showConnections() {
        guard let torrent = selectedTorrent else { return }
        refreshDetail(id: torrent.id) { [weak self] detail, error in
            if let detail { self?.onPresent?(.connections(detail)) }
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
        polling = nil
        do { try await application.shutdown() }
        catch { stopping = false; start(); throw error }
    }
}
