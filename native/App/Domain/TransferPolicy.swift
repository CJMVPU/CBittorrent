import Foundation

/// Unknown future engine states remain visible under All without being
/// incorrectly treated as downloading, paused or completed.
enum TransferState: String {
    case downloading, metadata, seeding, paused, queued, checking, error

    var filter: TaskFilter {
        switch self {
        case .downloading, .metadata: return .downloading
        case .seeding: return .seeding
        case .paused: return .paused
        case .queued: return .queued
        case .checking: return .checking
        case .error: return .error
        }
    }
}

struct FilePriorityChange {
    let index: Int
    let priority: Int

    init(index: Int, priority: Int) throws {
        guard (0...Int(Int32.max)).contains(index), (0...7).contains(priority) else {
            throw ClientError.message("文件索引或优先级无效。")
        }
        self.index = index
        self.priority = priority
    }
}

/// The first observed snapshot is a baseline, not a completion event.
struct CompletionTransitions {
    private var previousProgress: [String: Double] = [:]

    mutating func accept(_ torrents: [TorrentSnapshot]) -> [TorrentSnapshot] {
        let completed = torrents.filter {
            $0.progress >= 1 && previousProgress[$0.id].map { $0 < 1 } == true
        }
        previousProgress = Dictionary(torrents.map { ($0.id, $0.progress) }, uniquingKeysWith: { _, new in new })
        return completed
    }
}
