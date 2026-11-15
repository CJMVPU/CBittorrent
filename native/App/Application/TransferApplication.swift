import Foundation

struct AddTransfersResult {
    let accepted: [String]
    let failure: String?
}

enum TransferCommand {
    case resume([String])
    case pause([String])
    case remove([String], deleteFiles: Bool)
    case priority(id: String, index: Int, priority: Int)
}

/// Coordinates complete use cases, including persistence. MainActor alone would
/// not prevent another command from entering while an engine call is suspended.
@MainActor
final class TransferApplication {
    private let engine: any TransferEngine
    private let repository: any SettingsRepository
    private let directory: any DownloadDirectory
    private let notifier: any CompletionNotifier
    private(set) var settings: AppSettings
    private var tail: Task<Void, Never>?
    private var closing = false
    private var completions = CompletionTransitions()

    init(engine: any TransferEngine, repository: any SettingsRepository,
         directory: any DownloadDirectory, notifier: any CompletionNotifier,
         settings: AppSettings) {
        self.engine = engine
        self.repository = repository
        self.directory = directory
        self.notifier = notifier
        self.settings = settings
    }

    private func serialized<T>(_ operation: @escaping @MainActor () async throws -> T) async throws -> T {
        guard !closing else { throw ClientError.message("下载引擎正在关闭。") }
        let previous = tail
        let task = Task { @MainActor in
            await previous?.value
            return try await operation()
        }
        tail = Task { _ = try? await task.value }
        return try await task.value
    }

    func snapshot() async throws -> EngineSnapshot {
        try await serialized { [self] in
            var next = try await engine.snapshot()
            next.summary = TransferSummary(torrents: next.torrents)
            let completed = completions.accept(next.torrents)
            if settings.notifyOnCompletion {
                for torrent in completed { await notifier.completed(torrent) }
            }
            return next
        }
    }

    func detail(id: String) async throws -> TorrentSnapshot {
        try await serialized { [self] in try await engine.detail(id: id) }
    }

    /// Flush accepted mutations even when a later item in the batch fails.
    private func persistMutation(_ operation: () async throws -> Void) async throws {
        var failure: Error?
        do { try await operation() } catch { failure = error }
        do { try await engine.save(all: false) }
        catch {
            if let failure {
                throw ClientError.message("\(failure.localizedDescription)\n任务保存失败：\(error.localizedDescription)")
            }
            throw error
        }
        if let failure { throw failure }
    }

    func execute(_ command: TransferCommand) async throws {
        try await serialized { [self] in
            try await persistMutation {
                switch command {
                case .resume(let ids):
                    for id in ids { try await engine.resume(id: id) }
                case .pause(let ids):
                    for id in ids { try await engine.pause(id: id) }
                case .remove(let ids, let deleteFiles):
                    for id in ids { try await engine.remove(id: id, deleteFiles: deleteFiles) }
                case .priority(let id, let index, let priority):
                    let change = try FilePriorityChange(index: index, priority: priority)
                    try await engine.setFilePriority(id: id, index: change.index, priority: change.priority)
                }
            }
        }
    }

    func add(sources: [String]) async throws -> AddTransfersResult {
        try await serialized { [self] in
            var accepted: [String] = []
            var failure: String?
            do {
                try await persistMutation {
                    try await directory.prepare(path: settings.downloadPath)
                    for source in sources {
                        try await engine.add(source: source, savePath: settings.downloadPath, paused: settings.addPaused)
                        accepted.append(source)
                    }
                }
            } catch { failure = error.localizedDescription }
            return AddTransfersResult(accepted: accepted, failure: failure)
        }
    }

    func applyDefaultTrackers() async throws -> Int {
        try await serialized { [self] in
            var count = 0
            try await persistMutation { count = try await engine.applyDefaultTrackers() }
            return count
        }
    }

    func updateSettings(_ value: AppSettings) async throws {
        try await serialized { [self] in
            let next = try value.validated()
            let previous = settings
            try await directory.prepare(path: next.downloadPath)
            try await SettingsTransaction.commit {
                try await repository.save(next)
            } apply: {
                try await engine.applySettings(next)
            } rollback: {
                // Attempt both recoveries, even when disk restoration fails.
                var diskFailure: Error?
                do { try await repository.save(previous) } catch { diskFailure = error }
                do { try await engine.applySettings(previous) }
                catch {
                    if let diskFailure {
                        throw ClientError.message("\(diskFailure.localizedDescription)\n\(error.localizedDescription)")
                    }
                    throw error
                }
                if let diskFailure { throw diskFailure }
            }
            settings = next
            if next.notifyOnCompletion && !previous.notifyOnCompletion {
                await notifier.requestAuthorization()
            }
        }
    }

    func shutdown() async throws {
        guard !closing else { throw ClientError.message("下载引擎正在关闭。") }
        closing = true
        await tail?.value
        do { try await engine.close() }
        catch { closing = false; throw error }
    }
}
