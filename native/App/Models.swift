import Foundation

struct TorrentFileSnapshot: Codable, Identifiable {
    var index: Int
    var path: String
    var size: Int64
    var progress: Double
    var priority: Int
    var id: Int { index }
}

struct TrackerSnapshot: Codable {
    var url: String
    var status: String
}

struct TorrentSnapshot: Codable, Identifiable {
    var id: String
    var name: String
    var state: String
    var progress: Double
    var totalSize: Int64
    var downloaded: Int64
    var uploaded: Int64
    var downloadRate: Int64
    var uploadRate: Int64
    var eta: Int64
    var ratio: Double
    var peers: Int
    var seeds: Int
    var savePath: String
    var error: String
    var files: [TorrentFileSnapshot]
    var trackers: [TrackerSnapshot]
}

struct EngineSnapshot: Codable {
    var torrents: [TorrentSnapshot] = []
    var downloadRate: Int64 = 0
    var uploadRate: Int64 = 0
    var totalDownloaded: Int64 = 0
    var totalUploaded: Int64 = 0
    var dhtNodes: Int = 0
    var listenPort: Int = 0
    var errors: [String] = []
    var summary = TransferSummary(torrents: [])

    private enum CodingKeys: String, CodingKey {
        case torrents, downloadRate, uploadRate, totalDownloaded, totalUploaded, dhtNodes, listenPort, errors
    }
}

enum TaskFilter: String, CaseIterable {
    case all, downloading, seeding, paused, queued

    var title: String {
        switch self {
        case .all: return "全部任务"
        case .downloading: return "下载中"
        case .seeding: return "做种中"
        case .paused: return "已停止"
        case .queued: return "排队中"
        }
    }

    func matches(_ torrent: TorrentSnapshot) -> Bool {
        switch self {
        case .all: return true
        case .downloading: return torrent.state == "downloading" || torrent.state == "metadata"
        case .seeding: return torrent.state == "seeding"
        case .paused: return torrent.state == "paused"
        case .queued: return torrent.state == "queued"
        }
    }
}


enum ClientError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        }
    }
}

/// Computed once per engine update and reused by all presentation surfaces.
struct TransferSummary {
    let taskCount: Int
    let peerCount: Int
    private let counts: [TaskFilter: Int]

    init(torrents: [TorrentSnapshot]) {
        taskCount = torrents.count
        peerCount = torrents.reduce(0) { $0 + $1.peers }
        counts = Dictionary(uniqueKeysWithValues: TaskFilter.allCases.map { filter in
            (filter, torrents.reduce(0) { $0 + (filter.matches($1) ? 1 : 0) })
        })
    }

    func count(for filter: TaskFilter) -> Int { counts[filter, default: 0] }
}

struct TransferSelection {
    static func visible(torrents: [TorrentSnapshot], filter: TaskFilter, search: String) -> [TorrentSnapshot] {
        torrents.filter { filter.matches($0) && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func reconcile(_ selection: Set<String>, visible: [TorrentSnapshot]) -> Set<String> {
        selection.intersection(Set(visible.map(\.id)))
    }
}

/// Persist before applying policy, so a disk failure cannot stop live tasks.
enum SettingsTransaction {
    static func commit(persist: () throws -> Void, apply: () async throws -> Void,
                       rollback: () async throws -> Void) async throws {
        try persist()
        do { try await apply() }
        catch {
            let original = error
            do { try await rollback() }
            catch { throw ClientError.message("设置应用和恢复失败：\(original.localizedDescription)\n\(error.localizedDescription)") }
            throw original
        }
    }
}
