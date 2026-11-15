import AppKit

/// All widths fit the fixed footer, including the historical ratio.
enum StatusBarPresentation {
    static let widths: [CGFloat] = [104, 64, 88, 88, 194, 64, 114, 158]

    static func ratio(_ snapshot: EngineSnapshot) -> String {
        guard let downloaded = snapshot.historicalDownloaded,
              let uploaded = snapshot.historicalUploaded else { return "—" }
        guard downloaded > 0 else { return uploaded > 0 ? "∞" : "—" }
        return String(format: "%.2f", Double(uploaded) / Double(downloaded))
    }

    static func ratioTooltip(_ snapshot: EngineSnapshot) -> String {
        guard let downloaded = snapshot.historicalDownloaded,
              let uploaded = snapshot.historicalUploaded else { return "历史流量暂不可用" }
        return "历史累计上传 ÷ 下载：↑ \(Titanium.bytes(uploaded)) / ↓ \(Titanium.bytes(downloaded))\n重启和删除任务后保留；首次升级只导入现存任务可恢复的历史流量。"
    }
}
