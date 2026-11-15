import Foundation

struct TransferSelection {
    static func visible(torrents: [TorrentSnapshot], filter: TaskFilter, search: String) -> [TorrentSnapshot] {
        torrents.filter { filter.matches($0) && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)) }
            .sorted {
                let order = $0.name.localizedStandardCompare($1.name)
                return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
            }
    }

    static func reconcile(_ selection: Set<String>, visible: [TorrentSnapshot]) -> Set<String> {
        selection.intersection(Set(visible.map(\.id)))
    }
}


extension TaskFilter {
    var title: String {
        switch self {
        case .all: return "全部任务"
        case .downloading: return "下载中"
        case .seeding: return "做种中"
        case .paused: return "已停止"
        case .queued: return "排队中"
        case .checking: return "校验中"
        case .error: return "错误"
        }
    }

}
