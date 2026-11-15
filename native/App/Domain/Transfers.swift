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
    var message: String?
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
    var connections: [PeerSnapshot]?
    var metadataReady: Bool?
}

struct EngineSnapshot: Codable {
    var torrents: [TorrentSnapshot] = []
    var downloadRate: Int64 = 0
    var uploadRate: Int64 = 0
    var totalDownloaded: Int64 = 0
    var totalUploaded: Int64 = 0
    var historicalDownloaded: Int64?
    var historicalUploaded: Int64?
    var dhtNodes: Int = 0
    var listenPort: Int = 0
    var errors: [String] = []
    var summary = TransferSummary(torrents: [])

    private enum CodingKeys: String, CodingKey {
        case torrents, downloadRate, uploadRate, totalDownloaded, totalUploaded, historicalDownloaded, historicalUploaded, dhtNodes, listenPort, errors
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
        var peers = 0
        var totals: [TaskFilter: Int] = [.all: torrents.count]
        for torrent in torrents {
            peers += torrent.peers
            let filter = TransferState(rawValue: torrent.state)?.filter
            if let filter { totals[filter, default: 0] += 1 }
        }
        peerCount = peers
        counts = totals
    }

    func count(for filter: TaskFilter) -> Int { counts[filter, default: 0] }
}

enum TaskFilter: String, CaseIterable {
    case all, downloading, seeding, paused, queued, checking, error

    func matches(_ torrent: TorrentSnapshot) -> Bool {
        self == .all || TransferState(rawValue: torrent.state)?.filter == self
    }
}
