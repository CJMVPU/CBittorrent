import AppKit

/// Every application-owned interaction is a page inside the existing window.
enum InWindowRequest {
    case add
    case remove(ids: Set<String>)
    case files(TorrentSnapshot)
    case trackers(TorrentSnapshot)
    case message(title: String, body: String)
    case about
    case browseLocation(URL)
    case chooseDirectory(initial: URL, onSelect: (URL) -> Void)
}

final class InWindowFlowView: SurfaceView {
    private let store: AppStore
    private let onClose: () -> Void
    private let feedback = Titanium.label(size: 11, color: Titanium.muted)
    private var controls: [NSControl] = []
    private var sourceEditor: NSTextView?
    private var browser: InlineFileBrowser?
    private var detailView: TorrentDetailView?

    init(request: InWindowRequest, store: AppStore, onClose: @escaping () -> Void) {
        self.store = store
        self.onClose = onClose
        super.init(frame: NSRect(x: 0, y: 0, width: 900, height: 541), color: Titanium.panel)
        let back = button("返回", symbol: "arrow.left", frame: NSRect(x: 24, y: 16, width: 112, height: 28), action: onClose)
        back.restingColor = Titanium.background
        feedback.frame = NSRect(x: 28, y: 440, width: 844, height: 42)
        feedback.maximumNumberOfLines = 2
        feedback.cell?.wraps = true
        addSubview(feedback)
        switch request {
        case .add: buildAdd()
        case .remove(let ids): buildRemove(ids)
        case .files(let torrent): buildFiles(torrent)
        case .trackers(let torrent): buildTrackers(torrent)
        case .message(let title, let body):
            heading(title, subtitle: "")
            textArea(body, frame: NSRect(x: 28, y: 128, width: 844, height: 344))
            button("返回", frame: NSRect(x: 746, y: 493, width: 126, height: 32), action: onClose).active = true
        case .about:
            heading("关于 CBittorrent", subtitle: "原生 macOS · Apple Silicon")
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
            textArea("CBittorrent \(version)\n\nSwift / AppKit 原生界面，libtorrent 下载引擎。\n参考 qBittorrent 的业务逻辑；GPL-2.0-or-later。\n\n字体：LXGW WenKai Mono Medium\n运行平台：macOS 27 及更新版本 · Apple Silicon", frame: NSRect(x: 28, y: 145, width: 844, height: 280))
        case .browseLocation(let initial):
            showBrowser(mode: .browse, initial: initial) { _ in }
        case .chooseDirectory(let initial, let onSelect):
            showBrowser(mode: .directory, initial: initial) { [weak self] urls in
                guard let url = urls.first else { return }
                onSelect(url)
                self?.onClose()
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    private func heading(_ title: String, subtitle: String) {
        let name = Titanium.label(title, size: 20)
        name.frame = NSRect(x: 28, y: 61, width: 844, height: 32)
        name.toolTip = title
        addSubview(name)
        let description = Titanium.label(subtitle, size: 11, color: Titanium.muted)
        description.frame = NSRect(x: 28, y: 100, width: 844, height: 34)
        description.maximumNumberOfLines = 2
        description.cell?.wraps = true
        description.toolTip = subtitle
        addSubview(description)
    }

    @discardableResult
    private func button(_ title: String, symbol: String? = nil, frame: NSRect, action: @escaping () -> Void) -> ActionButton {
        let result = ActionButton(title, symbol: symbol, frame: frame, action: action)
        result.fitWidthToContent(keepingTrailingEdge: frame.maxX == 872)
        addSubview(result)
        controls.append(result)
        return result
    }

    @discardableResult
    private func textArea(_ text: String, frame: NSRect, editable: Bool = false) -> NSTextView {
        let scroll = NSScrollView(frame: frame)
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        let editor = NSTextView(frame: scroll.contentView.bounds)
        editor.isEditable = editable
        editor.isSelectable = true
        editor.isRichText = false
        editor.importsGraphics = false
        editor.font = Titanium.font(12)
        editor.textColor = Titanium.text
        editor.backgroundColor = Titanium.background
        editor.textContainerInset = NSSize(width: 10, height: 8)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.string = text
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        scroll.documentView = editor
        addSubview(scroll)
        return editor
    }

    private func showFeedback(_ text: String, error: Bool = false) {
        feedback.stringValue = text
        feedback.toolTip = text
        feedback.textColor = error ? Titanium.red : Titanium.green
    }

    private func setBusy(_ busy: Bool) {
        controls.forEach { $0.isEnabled = !busy }
        sourceEditor?.isEditable = !busy
    }

    private func buildAdd() {
        heading("添加下载任务", subtitle: "每行粘贴一个磁力链接或种子文件路径，也可拖入 .torrent 文件。保存位置：\(store.settings.downloadPath)")
        let editor = textArea("", frame: NSRect(x: 28, y: 145, width: 844, height: 232), editable: true)
        editor.setAccessibilityLabel("磁力链接或种子文件路径")
        sourceEditor = editor
        registerForDraggedTypes([.fileURL])
        button("浏览种子文件", symbol: "folder", frame: NSRect(x: 28, y: 391, width: 166, height: 32)) { [weak self] in
            guard let self else { return }
            self.showBrowser(mode: .torrents, initial: URL(fileURLWithPath: self.store.settings.downloadPath)) { [weak self] urls in
                self?.appendSources(urls)
                self?.browser?.removeFromSuperview()
                self?.browser = nil
            }
        }.restingColor = Titanium.background
        let state = Titanium.label(store.settings.addPaused ? "新任务将以停止状态加入" : "新任务将按队列设置开始传输", size: 11, color: Titanium.muted)
        state.frame = NSRect(x: 214, y: 396, width: 638, height: 24)
        addSubview(state)
        button("添加任务", symbol: "plus", frame: NSRect(x: 730, y: 493, width: 142, height: 32)) { [weak self] in self?.submitSources() }.active = true
    }

    private func appendSources(_ urls: [URL]) {
        guard let editor = sourceEditor else { return }
        let additions = urls.filter { $0.isFileURL && $0.pathExtension.lowercased() == "torrent" }.map(\.path)
        let current = editor.string.trimmingCharacters(in: .whitespacesAndNewlines)
        editor.string = ([current].filter { !$0.isEmpty } + additions).joined(separator: "\n")
        showFeedback("已选择 \(additions.count) 个种子文件；点击添加任务开始导入。")
    }

    private func submitSources() {
        guard let editor = sourceEditor else { return }
        do {
            var sources: [String] = []
            for line in editor.string.components(separatedBy: .newlines) {
                let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if value.isEmpty { continue }
                let source: String
                if value.lowercased().hasPrefix("magnet:?") {
                    source = "magnet:" + value.dropFirst(7)
                } else {
                    let url: URL
                    if value.hasPrefix("file:"), let parsed = URL(string: value), parsed.isFileURL { url = parsed }
                    else { url = URL(fileURLWithPath: (value as NSString).expandingTildeInPath) }
                    var isDirectory: ObjCBool = false
                    guard url.pathExtension.lowercased() == "torrent",
                          FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                        throw ClientError.message("请输入有效磁力链接或存在的 .torrent 文件路径：\(value)")
                    }
                    source = url.standardizedFileURL.path
                }
                if !sources.contains(source) { sources.append(source) }
            }
            guard !sources.isEmpty else { throw ClientError.message("先输入磁力链接，或选择种子文件。") }
            setBusy(true)
            showFeedback("正在添加任务…")
            store.addFromForm(sources: sources) { [weak self] accepted, error in
                guard let self else { return }
                self.setBusy(false)
                if let error {
                    self.sourceEditor?.string = sources.filter { !accepted.contains($0) }.joined(separator: "\n")
                    self.showFeedback("已加入 \(accepted.count) 个任务。\(error)", error: true)
                } else { self.onClose() }
            }
        } catch { showFeedback(error.localizedDescription, error: true) }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        sourceEditor?.isEditable == true ? .copy : []
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard sourceEditor?.isEditable == true,
              let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] else { return false }
        appendSources(urls)
        return true
    }

    private func buildRemove(_ ids: Set<String>) {
        heading("移除 \(ids.count) 个任务", subtitle: "移除后任务将从列表消失。默认保留已经下载的文件。")
        let names = store.snapshot.torrents.filter { ids.contains($0.id) }.map(\.name)
        textArea(names.joined(separator: "\n"), frame: NSRect(x: 28, y: 145, width: 844, height: 225))
        let delete = NSButton(checkboxWithTitle: "同时永久删除下载文件", target: nil, action: nil)
        delete.frame = NSRect(x: 28, y: 389, width: 420, height: 28)
        delete.font = Titanium.font(12)
        delete.state = .off
        addSubview(delete)
        controls.append(delete)
        button("确认移除", symbol: "trash", frame: NSRect(x: 730, y: 493, width: 142, height: 32)) { [weak self, weak delete] in
            guard let self else { return }
            self.setBusy(true)
            self.store.confirmedRemove(ids: ids, deleteFiles: delete?.state == .on) { [weak self] error in
                guard let self else { return }
                self.setBusy(false)
                if let error { self.showFeedback(error, error: true) }
                else { self.onClose() }
            }
        }.tint = Titanium.red
    }

    private func buildFiles(_ torrent: TorrentSnapshot) {
        buildDetails(torrent, filesMode: true)
    }

    private func buildTrackers(_ torrent: TorrentSnapshot) {
        buildDetails(torrent, filesMode: false)
    }

    private func buildDetails(_ torrent: TorrentSnapshot, filesMode: Bool) {
        heading(filesMode ? "任务文件" : "任务 Tracker", subtitle: torrent.name)
        let view = TorrentDetailView(torrent: torrent, filesMode: filesMode, store: store)
        detailView = view
        addSubview(view)
    }

    func refreshDetails() { detailView?.refresh() }

    private func showBrowser(mode: InlineFileBrowser.Mode, initial: URL, onSelect: @escaping ([URL]) -> Void) {
        let picker = InlineFileBrowser(frame: bounds, mode: mode, initial: initial, onSelect: onSelect) { [weak self] in
            guard let self else { return }
            self.browser?.removeFromSuperview()
            self.browser = nil
            if self.sourceEditor == nil { self.onClose() }
        }
        browser = picker
        addSubview(picker)
    }
}
