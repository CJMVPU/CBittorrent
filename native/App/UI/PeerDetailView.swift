import AppKit

/// Connection information is a read-only projection, refreshed only while visible.
final class PeerDetailView: SurfaceView, NSTableViewDataSource, NSTableViewDelegate {
    private let store: AppStore
    private let torrentID: String
    private let table = NSTableView()
    private let summary = Titanium.label(size: 11, color: Titanium.muted)
    private let details = Titanium.label(size: 11, color: Titanium.muted)
    private let search = NSSearchField()
    private let refreshButton = ActionButton("刷新", symbol: "arrow.clockwise")
    private var peers: [PeerSnapshot] = []
    private var visible: [PeerSnapshot] = []
    private var fetching = false
    private var lastRefresh = Date.distantPast
    private var updating = false
    private var automaticRefresh = true
    private let autoButton = ActionButton("暂停刷新")

    init(torrent: TorrentSnapshot, store: AppStore) {
        self.store = store
        torrentID = torrent.id
        super.init(frame: NSRect(x: 28, y: 130, width: 844, height: 390))
        search.frame = NSRect(x: 0, y: 0, width: 300, height: 28)
        search.placeholderString = "筛选 IP、客户端或协议"
        search.setAccessibilityLabel("筛选连接")
        search.target = self
        search.action = #selector(filterChanged)
        search.sendsSearchStringImmediately = true
        addSubview(search)
        summary.frame = NSRect(x: 316, y: 4, width: 292, height: 22)
        addSubview(summary)
        autoButton.frame = NSRect(x: 622, y: 0, width: 118, height: 28)
        autoButton.handler = { [weak self] in
            guard let self else { return }
            self.automaticRefresh.toggle()
            self.autoButton.setTitle(self.automaticRefresh ? "暂停刷新" : "继续刷新")
            self.autoButton.setAccessibilityLabel(self.autoButton.title)
            self.filterChanged()
            if self.automaticRefresh { self.lastRefresh = .distantPast; self.refresh() }
        }
        addSubview(autoButton)
        refreshButton.frame = NSRect(x: 752, y: 0, width: 92, height: 28)
        refreshButton.handler = { [weak self] in self?.lastRefresh = .distantPast; self?.refresh(manual: true) }
        addSubview(refreshButton)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 40, width: 844, height: 266))
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder
        table.frame = NSRect(x: 0, y: 0, width: 844, height: 266)
        table.rowHeight = 28
        table.intercellSpacing = .zero
        table.usesAlternatingRowBackgroundColors = true
        table.style = .plain
        table.backgroundColor = Titanium.panel
        table.allowsColumnReordering = false
        table.allowsColumnResizing = false
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.headerView = QuietHeaderView(frame: NSRect(x: 0, y: 0, width: 844, height: 25))
        let columns: [(String, CGFloat)] = [("节点 IP : 端口", 214), ("客户端", 174), ("进度", 68),
            ("↓ 下载 /s", 100), ("↑ 上传 /s", 100), ("协议", 72), ("方向", 108)]
        for (index, entry) in columns.enumerated() {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(String(index)))
            column.width = entry.1
            column.resizingMask = []
            column.headerCell = QuietHeaderCell(textCell: entry.0)
            column.headerCell.alignment = (2...4).contains(index) ? .right : .left
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityLabel("任务连接列表")
        scroll.documentView = table
        addSubview(scroll)
        details.frame = NSRect(x: 0, y: 320, width: 844, height: 68)
        details.maximumNumberOfLines = 3
        details.cell?.wraps = true
        details.isSelectable = true
        addSubview(details)
        accept(torrent.connections ?? [])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func refresh(manual: Bool = false) {
        guard automaticRefresh || manual else { return }
        guard !fetching, window != nil, !isHiddenOrHasHiddenAncestor,
              Date().timeIntervalSince(lastRefresh) >= 2 else { return }
        guard store.snapshot.torrents.contains(where: { $0.id == torrentID }) else {
            accept([])
            summary.stringValue = "任务已移除"
            refreshButton.isEnabled = false
            return
        }
        fetching = true
        refreshButton.isEnabled = false
        lastRefresh = Date()
        store.refreshDetail(id: torrentID) { [weak self] value, error in
            guard let self else { return }
            self.fetching = false
            self.refreshButton.isEnabled = true
            if let value { self.accept(value.connections ?? []) }
            else {
                self.summary.stringValue = "刷新失败 · 显示上次结果"
                self.details.stringValue = error ?? "连接信息不可用"
            }
        }
    }

    private func accept(_ values: [PeerSnapshot]) {
        let ranks = ["connected": 0, "handshake": 1, "connecting": 2]
        peers = values.sorted {
            let left = ranks[$0.state, default: 3], right = ranks[$1.state, default: 3]
            return left == right ? $0.id < $1.id : left < right
        }
        filterChanged()
    }

    @objc private func filterChanged() {
        let selected = visible.indices.contains(table.selectedRow) ? visible[table.selectedRow].id : nil
        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        visible = peers.filter { query.isEmpty || "\($0.endpoint) \($0.client) \($0.transport)".localizedCaseInsensitiveContains(query) }
        updating = true
        table.reloadData()
        if let index = visible.firstIndex(where: { $0.id == selected }) { table.selectRowIndexes([index], byExtendingSelection: false) }
        else { table.deselectAll(nil) }
        updating = false
        summary.stringValue = "\(visible.count) / \(peers.count) 个连接 · \(automaticRefresh ? "每 2 秒刷新" : "已暂停刷新")"
        showSelection()
    }
    func numberOfRows(in tableView: NSTableView) -> Int { visible.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard visible.indices.contains(row), let key = tableColumn?.identifier, let column = Int(key.rawValue) else { return nil }
        let peer = visible[row]
        let cell = (tableView.makeView(withIdentifier: key, owner: self) as? ValueCell) ?? ValueCell()
        cell.identifier = key
        let values = [peer.endpoint, peer.client.isEmpty ? (peer.state == "connecting" ? "连接中" : peer.state == "handshake" ? "等待握手" : "未提供") : peer.client,
            peer.state == "connected" ? "\(Int(min(1, max(0, peer.progress)) * 100))%" : "—", Titanium.rate(peer.downloadRate), Titanium.rate(peer.uploadRate),
            peer.transport, peer.outgoing ? "出站" : "入站"]
        cell.label.stringValue = values[column]
        cell.label.font = Titanium.font(11)
        cell.label.alignment = (2...4).contains(column) ? .right : .left
        cell.toolTip = values[column]
        return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) { if !updating { showSelection() } }
    private func showSelection() {
        guard visible.indices.contains(table.selectedRow) else {
            details.stringValue = peers.isEmpty
                ? "当前没有连接。任务停止、等待元数据或尚未发现节点时可能出现此状态。"
                : "选择一个连接，查看本地端点、加密、来源和传输状态。\n速率和累计量均以本机为视角；入站连接不代表端口始终可从公网访问。"
            return
        }
        let peer = visible[table.selectedRow]
        let encryption = peer.encryption == "RC4" ? "RC4 加密" : peer.encryption == "Handshake" ? "仅握手混淆" : "未加密"
        let state = peer.state == "connecting" ? "连接中" : peer.state == "handshake" ? "握手中" : "已连接"
        details.stringValue = "本地 \(peer.localEndpoint) → 远端 \(peer.endpoint) · \(state) · \(encryption)\n"
            + "已下载 \(Titanium.bytes(peer.downloaded)) · 已上传 \(Titanium.bytes(peer.uploaded)) · 来源 \(peer.sources.isEmpty ? "未知" : peer.sources.joined(separator: "、"))\n"
            + "本机上传：\(peer.uploadChoked ? "暂未允许" : "允许") · 对端上传：\(peer.downloadChoked ? "暂未允许" : "允许") · 对端需求：\(peer.remoteInterested.map { $0 ? "需要数据" : "暂无需求" } ?? "未知")"
    }
}
