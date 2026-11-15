import Foundation

/// Application-owned port. Only its infrastructure adapter knows the C ABI.
protocol TransferEngine: AnyObject {
    func snapshot() async throws -> EngineSnapshot
    func detail(id: String) async throws -> TorrentSnapshot
    func add(source: String, savePath: String, paused: Bool) async throws
    func prepareMetadata(source: String) async throws -> String
    func cancelMetadata(id: String) async throws
    func confirmMetadata(id: String, savePath: String, paused: Bool) async throws
    func pause(id: String) async throws
    func resume(id: String) async throws
    func remove(id: String, deleteFiles: Bool) async throws
    func setFilePriority(id: String, index: Int, priority: Int) async throws
    func applySettings(_ settings: AppSettings) async throws
    func applyDefaultTrackers() async throws -> Int
    func save(all: Bool) async throws
    func close() async throws
}

@MainActor
protocol SettingsRepository {
    func load() throws -> AppSettings
    func save(_ settings: AppSettings) async throws
}

@MainActor
protocol DownloadDirectory {
    func prepare(path: String) async throws
}

@MainActor
protocol CompletionNotifier {
    func requestAuthorization() async
    func completed(_ torrent: TorrentSnapshot) async
}

// Unsupported adapters fail explicitly; production implements all preview operations.
extension TransferEngine {
    func prepareMetadata(source: String) async throws -> String { throw ClientError.message("不支持元数据预览。") }
    func cancelMetadata(id: String) async throws {}
    func confirmMetadata(id: String, savePath: String, paused: Bool) async throws { throw ClientError.message("不支持元数据预览。") }
}
