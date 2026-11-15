import AppKit

/// One source is inspected at a time; only an explicit confirmation creates a transfer.
final class MetadataReviewView: SurfaceView {
    private let store: AppStore
    private var sources: [String]
    private let finish: () -> Void
    private let title = Titanium.label(size: 15)
    private let status = Titanium.label(size: 11, color: Titanium.muted)
    private let list = FlowListView(frame: NSRect(x: 0, y: 91, width: 844, height: 228))
    private let confirm = ActionButton("确认添加")
    private let skip = ActionButton("跳过此项")
    private let retry = ActionButton("重新获取")
    private var operation: Task<Void, Never>?
    private var previewID: String?
    private var stopped = false
    private var committed = 0

    init(sources: [String], store: AppStore, finish: @escaping () -> Void) {
        self.sources = sources
        self.store = store
        self.finish = finish
        super.init(frame: NSRect(x: 28, y: 140, width: 844, height: 390))
        title.frame = NSRect(x: 0, y: 0, width: 844, height: 25)
        status.frame = NSRect(x: 0, y: 30, width: 844, height: 54)
        status.maximumNumberOfLines = 3
        status.cell?.wraps = true
        addSubview(title); addSubview(status); addSubview(list)
        confirm.frame = NSRect(x: 690, y: 351, width: 154, height: 32)
        confirm.active = true
        confirm.handler = { [weak self] in self?.commit() }
        skip.frame = NSRect(x: 0, y: 351, width: 128, height: 32)
        skip.handler = { [weak self] in self?.next() }
        retry.frame = NSRect(x: 144, y: 351, width: 128, height: 32)
        retry.handler = { [weak self] in self?.load() }
        addSubview(confirm); addSubview(skip); addSubview(retry)
        load()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func cancel() {
        stopped = true
        operation?.cancel()
        let pending = operation
        Task { [self] in
            await pending?.value
            if let id = previewID {
                previewID = nil
                await store.cancelMetadata(id: id)
            }
        }
    }

    private func load() {
        let pending = operation
        pending?.cancel()
        guard let source = sources.first, !stopped else { return }
        confirm.isEnabled = false
        retry.isEnabled = false
        list.strings = []
        title.stringValue = "正在检查元数据 · 剩余 \(sources.count) 项 · 已添加 \(committed) 项"
        status.stringValue = "磁力链接需要连接节点获取元数据，尚未下载文件正文。\n\(source)"
        operation = Task { [weak self, store] in
            await pending?.value
            if let previous = self?.previewID {
                self?.previewID = nil
                await store.cancelMetadata(id: previous)
            }
            var acquired: String?
            do {
                try Task.checkCancellation()
                let id = try await store.prepareMetadata(source: source)
                acquired = id
                try Task.checkCancellation()
                self?.previewID = id
                let deadline = Date().addingTimeInterval(120)
                while Date() < deadline {
                    try Task.checkCancellation()
                    let value = try await store.metadataDetail(id: id)
                    try Task.checkCancellation()
                    if value.metadataReady == true {
                        guard let self, !self.stopped else { break }
                        self.title.stringValue = value.name
                        self.title.toolTip = value.name
                        self.status.stringValue = "总大小 \(Titanium.bytes(value.totalSize)) · \(value.files.count) 个文件 · Hash \(value.id)\n保存到：\(store.settings.downloadPath)\n确认后\(store.settings.addPaused ? "以停止状态加入" : "按队列设置开始下载")；元数据不代表文件内容安全或真实。"
                        self.list.strings = value.files.map { "\(Titanium.bytes($0.size))  ·  \($0.path)" }
                        self.confirm.isEnabled = true
                        self.retry.isEnabled = true
                        return
                    }
                    if !value.error.isEmpty { throw ClientError.message(value.error) }
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                }
                throw ClientError.message("获取元数据超时，可能没有可用节点。可以重试或跳过。")
            } catch {
                if let acquired {
                    await store.cancelMetadata(id: acquired)
                    if self?.previewID == acquired { self?.previewID = nil }
                }
                guard !Task.isCancelled, let self, !self.stopped else { return }
                self.previewID = nil
                self.status.stringValue = error.localizedDescription
                self.retry.isEnabled = true
            }
        }
    }

    private func next() {
        operation?.cancel()
        if !sources.isEmpty { sources.removeFirst() }
        if sources.isEmpty { cancel(); finish() }
        else { load() }
    }

    private func commit() {
        guard let id = previewID else { return }
        confirm.isEnabled = false; skip.isEnabled = false; retry.isEnabled = false
        operation = Task { [weak self, store] in
            do {
                try await store.confirmMetadata(id: id)
                guard let self, !self.stopped else { return }
                self.previewID = nil
                self.committed += 1
                self.operation = nil
                self.skip.isEnabled = true
                self.next()
            } catch {
                guard let self, !self.stopped else { return }
                self.status.stringValue = "添加未完成：\(error.localizedDescription)\n已提交的任务可能已加入列表；请检查列表后重试。"
                self.skip.isEnabled = true; self.retry.isEnabled = true
            }
        }
    }
}
