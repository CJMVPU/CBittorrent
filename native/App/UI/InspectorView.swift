import AppKit

final class InspectorView: SurfaceView {
    private let title = Titanium.label("任务检查器", size: 11, color: Titanium.muted)
    private let nameLabel = Titanium.label(size: 12)
    private let sizeLabel = Titanium.label(size: 10, color: Titanium.muted)
    private let percent = Titanium.label("—", size: 26)
    private let state = Titanium.label(size: 11, alignment: .right)
    private let progress = ProgressTrack()
    private var values: [NSTextField] = []
    private let pathLabel = Titanium.label(size: 11, color: Titanium.muted)
    private let filesLabel = Titanium.label(size: 11, color: Titanium.muted)
    private let errorLabel = Titanium.label(size: 10, color: Titanium.red)
    private let filesButton: ActionButton
    private let trackersButton: ActionButton
    private let revealButton: ActionButton
    private let closeButton: ActionButton

    init(store: AppStore, onClose: @escaping () -> Void) {
        filesButton = ActionButton("查看文件", symbol: "doc.on.doc", action: { [weak store] in store?.showFiles() })
        trackersButton = ActionButton("Tracker", symbol: "network", action: { [weak store] in store?.showTrackers() })
        revealButton = ActionButton("在访达中显示", symbol: "folder", action: { [weak store] in store?.revealSelected() })
        closeButton = ActionButton(symbol: "xmark", action: onClose)
        super.init(color: Titanium.background, radius: 10)
        layer?.shadowColor = NSColor(hex: 0x26344E).cgColor
        layer?.shadowOpacity = 0.14
        layer?.shadowRadius = 16
        layer?.shadowOffset = NSSize(width: 0, height: -5)
        closeButton.toolTip = "关闭任务检查器"
        closeButton.setAccessibilityLabel("关闭任务检查器")
        nameLabel.maximumNumberOfLines = 3
        nameLabel.cell?.wraps = true
        nameLabel.lineBreakMode = .byWordWrapping
        pathLabel.maximumNumberOfLines = 2
        pathLabel.cell?.wraps = true
        pathLabel.lineBreakMode = .byTruncatingMiddle
        errorLabel.maximumNumberOfLines = 3
        errorLabel.cell?.wraps = true
        let views: [NSView] = [title, nameLabel, sizeLabel, percent, state, progress, pathLabel, filesLabel, errorLabel,
                               filesButton, trackersButton, revealButton, closeButton]
        for view in views {
            addSubview(view)
        }
        for (index, caption) in ["下载", "上传", "剩余时间", "分享率", "连接", "已下载", "已上传"].enumerated() {
            let label = Titanium.label(caption, size: 11, color: Titanium.muted)
            label.frame = NSRect(x: 17, y: CGFloat(190 + index * 25), width: 66, height: 18)
            let value = Titanium.label("—", size: 11, alignment: .right)
            value.frame = NSRect(x: 84, y: CGFloat(190 + index * 25), width: 147, height: 18)
            values.append(value)
            addSubview(label)
            addSubview(value)
        }
        let locationHeading = Titanium.label("存储位置", size: 10, color: Titanium.muted)
        locationHeading.frame = NSRect(x: 17, y: 381, width: 200, height: 16)
        addSubview(locationHeading)
        let filesHeading = Titanium.label("文件", size: 10, color: Titanium.muted)
        filesHeading.frame = NSRect(x: 17, y: 453, width: 200, height: 16)
        addSubview(filesHeading)
        filesButton.restingColor = Titanium.panel
        trackersButton.restingColor = Titanium.panel
        revealButton.tint = Titanium.accent
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func layout() {
        super.layout()
        title.frame = NSRect(x: 17, y: 17, width: 170, height: 18)
        closeButton.frame = NSRect(x: bounds.width - 37, y: 12, width: 22, height: 22)
        nameLabel.frame = NSRect(x: 17, y: 55, width: 214, height: 55)
        sizeLabel.frame = NSRect(x: 17, y: 113, width: 214, height: 16)
        percent.frame = NSRect(x: 17, y: 141, width: 110, height: 34)
        state.frame = NSRect(x: 131, y: 155, width: 100, height: 18)
        progress.frame = NSRect(x: 17, y: 178, width: 214, height: 4)
        pathLabel.frame = NSRect(x: 17, y: 403, width: 214, height: 34)
        revealButton.frame = NSRect(x: 11, y: 429, width: 126, height: 22)
        filesLabel.frame = NSRect(x: 17, y: 475, width: 214, height: 18)
        errorLabel.frame = NSRect(x: 17, y: 495, width: 214, height: 34)
        filesButton.frame = NSRect(x: 17, y: bounds.height - 40, width: 103, height: 26)
        trackersButton.frame = NSRect(x: 128, y: bounds.height - 40, width: 103, height: 26)
    }

    func update(_ torrent: TorrentSnapshot?) {
        let enabled = torrent != nil
        filesButton.isEnabled = enabled
        trackersButton.isEnabled = enabled
        revealButton.isEnabled = enabled
        guard let torrent else {
            nameLabel.stringValue = "选择一个任务\n查看传输详情"
            sizeLabel.stringValue = ""
            percent.stringValue = "—"
            state.stringValue = ""
            progress.progress = 0
            values.forEach { $0.stringValue = "—" }
            pathLabel.stringValue = "—"
            filesLabel.stringValue = "—"
            errorLabel.stringValue = ""
            return
        }
        nameLabel.stringValue = torrent.name
        nameLabel.toolTip = torrent.name
        sizeLabel.stringValue = "\(Titanium.bytes(torrent.totalSize)) · \(torrent.files.count) 个文件"
        percent.stringValue = "\(Int(min(1, max(0, torrent.progress)) * 100))%"
        state.stringValue = Titanium.state(torrent.state)
        state.textColor = Titanium.stateColor(torrent.state)
        progress.progress = torrent.progress
        progress.tint = torrent.state == "seeding" ? Titanium.green : Titanium.accent
        let detailValues = [
            "\(Titanium.bytes(torrent.downloadRate))/s", "\(Titanium.bytes(torrent.uploadRate))/s",
            Titanium.duration(torrent.eta), String(format: "%.2f", torrent.ratio),
            "\(torrent.peers) 节点 · \(torrent.seeds) 种子", Titanium.bytes(torrent.downloaded), Titanium.bytes(torrent.uploaded)
        ]
        for (label, text) in zip(values, detailValues) { label.stringValue = text }
        pathLabel.stringValue = (torrent.savePath as NSString).abbreviatingWithTildeInPath
        pathLabel.toolTip = torrent.savePath
        filesLabel.stringValue = torrent.files.first?.path ?? "等待元数据"
        filesLabel.toolTip = torrent.files.map(\.path).joined(separator: "\n")
        errorLabel.stringValue = torrent.error
        errorLabel.toolTip = torrent.error.isEmpty ? nil : torrent.error
    }
}
