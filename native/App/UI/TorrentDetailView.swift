import AppKit

/// Detail payloads are fetched only while this page is visible.
final class TorrentDetailView: SurfaceView {
    private let store: AppStore
    private let torrentID: String
    private let filesMode: Bool
    private var torrent: TorrentSnapshot
    private var fetching = false
    private var applying = false
    private var editRevision = 0
    private var lastRefresh = Date.distantPast
    private let list = FlowListView(frame: NSRect(x: 0, y: 0, width: 844, height: 278))
    private let priority = NSPopUpButton(frame: NSRect(x: 0, y: 348, width: 160, height: 30))
    private let apply = ActionButton("应用优先级", frame: NSRect(x: 690, y: 348, width: 154, height: 32))
    private let feedback = Titanium.label(size: 11, color: Titanium.muted)

    init(torrent: TorrentSnapshot, filesMode: Bool, store: AppStore) {
        self.store = store
        self.torrent = torrent
        self.torrentID = torrent.id
        self.filesMode = filesMode
        super.init(frame: NSRect(x: 28, y: 145, width: 844, height: 380))
        addSubview(list)
        feedback.frame = NSRect(x: 0, y: 290, width: 844, height: 42)
        feedback.maximumNumberOfLines = 2
        feedback.cell?.wraps = true
        addSubview(feedback)
        if filesMode {
            priority.font = Titanium.font(12)
            priority.addItems(withTitles: ["跳过", "低优先级", "正常优先级", "高优先级"])
            priority.setAccessibilityLabel("文件优先级")
            addSubview(priority)
            apply.active = true
            apply.fitWidthToContent(keepingTrailingEdge: true)
            apply.handler = { [weak self] in self?.applyPriority() }
            addSubview(apply)
            list.onSelection = { [weak self] in self?.selectionChanged() }
        }
        render(torrent)
        if filesMode && !torrent.files.isEmpty { list.select(0) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func refresh() {
        guard !fetching, !applying, Date().timeIntervalSince(lastRefresh) >= 1 else { return }
        guard store.snapshot.torrents.contains(where: { $0.id == torrentID }) else {
            priority.isEnabled = false
            apply.isEnabled = false
            feedback.stringValue = "此任务已移除。"
            return
        }
        lastRefresh = Date()
        fetching = true
        let revision = editRevision
        store.refreshDetail(id: torrentID) { [weak self] value, error in
            guard let self else { return }
            self.fetching = false
            // An earlier read must not overwrite an in-flight priority edit.
            guard !self.applying, revision == self.editRevision else { return }
            if let value { self.render(value) }
            else if let error {
                self.feedback.stringValue = error
                self.feedback.textColor = Titanium.red
            }
        }
    }

    private func render(_ value: TorrentSnapshot) {
        torrent = value
        list.strings = filesMode
            ? value.files.map { "\(Int(min(1, max(0, $0.progress)) * 100))%  ·  \(Titanium.bytes($0.size))  ·  \($0.path)" }
            : value.trackers.map { $0.url }
        if list.strings.isEmpty {
            feedback.stringValue = filesMode ? "正在获取元数据，文件列表将自动更新。" : "此任务尚无 Tracker。"
        } else if feedback.stringValue == "正在获取元数据，文件列表将自动更新。" || feedback.stringValue == "此任务尚无 Tracker。" {
            feedback.stringValue = ""
        }
        if filesMode { updateEnabled() }
    }

    private func updateEnabled() {
        let valid = list.selectedIndexes.first.map { torrent.files.indices.contains($0) } ?? false
        priority.isEnabled = valid && !applying
        apply.isEnabled = valid && !applying
    }

    private func selectionChanged() {
        updateEnabled()
        guard let row = list.selectedIndexes.first, torrent.files.indices.contains(row) else { return }
        let raw = torrent.files[row].priority
        priority.selectItem(at: raw == 0 ? 0 : raw == 1 ? 1 : raw >= 5 ? 3 : 2)
    }

    private func applyPriority() {
        guard !applying, let row = list.selectedIndexes.first, torrent.files.indices.contains(row) else { return }
        let choice = priority.indexOfSelectedItem
        guard (0..<4).contains(choice) else { return }
        let index = torrent.files[row].index
        let value = [0, 1, 4, 7][choice]
        editRevision += 1
        applying = true
        updateEnabled()
        store.applyFilePriority(id: torrentID, index: index, priority: value) { [weak self] error in
            guard let self else { return }
            self.applying = false
            if error == nil, let current = self.torrent.files.firstIndex(where: { $0.index == index }) {
                self.torrent.files[current].priority = value
            }
            self.feedback.stringValue = error ?? "文件优先级已保存。"
            self.feedback.textColor = error == nil ? Titanium.green : Titanium.red
            self.updateEnabled()
            self.lastRefresh = .distantPast
        }
    }
}
