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
        heading("任务文件", subtitle: torrent.name)
        guard !torrent.files.isEmpty else {
            textArea("正在获取元数据。获取完成后，请重新打开文件列表。", frame: NSRect(x: 28, y: 145, width: 844, height: 250))
            return
        }
        let list = FlowListView(frame: NSRect(x: 28, y: 145, width: 844, height: 278))
        list.strings = torrent.files.map { "\(Int($0.progress * 100))%  ·  \(Titanium.bytes($0.size))  ·  \($0.path)" }
        addSubview(list)
        let priority = NSPopUpButton(frame: NSRect(x: 28, y: 493, width: 160, height: 30))
        priority.font = Titanium.font(12)
        priority.addItems(withTitles: ["跳过", "低优先级", "正常优先级", "高优先级"])
        addSubview(priority)
        controls.append(priority)
        var priorities = torrent.files.map(\.priority)
        list.onSelection = { [weak priority, weak list] in
            guard let row = list?.selectedIndexes.first, torrent.files.indices.contains(row) else { return }
            let raw = priorities[row]
            priority?.selectItem(at: raw == 0 ? 0 : raw == 1 ? 1 : raw >= 5 ? 3 : 2)
        }
        list.select(0)
        button("应用优先级", frame: NSRect(x: 718, y: 493, width: 154, height: 32)) { [weak self, weak list, weak priority] in
            guard let self, let row = list?.selectedIndexes.first, torrent.files.indices.contains(row),
                  let choice = priority?.indexOfSelectedItem, (0..<4).contains(choice) else { return }
            self.setBusy(true)
            self.store.applyFilePriority(id: torrent.id, index: torrent.files[row].index, priority: [0, 1, 4, 7][choice]) { [weak self] error in
                self?.setBusy(false)
                if error == nil { priorities[row] = [0, 1, 4, 7][choice] }
                self?.showFeedback(error ?? "文件优先级已保存。", error: error != nil)
            }
        }.active = true
    }

    private func buildTrackers(_ torrent: TorrentSnapshot) {
        heading("任务 Tracker", subtitle: torrent.name)
        let text = torrent.trackers.isEmpty ? "此任务尚无 Tracker。" : torrent.trackers.map { $0.url }.joined(separator: "\n\n")
        textArea(text, frame: NSRect(x: 28, y: 145, width: 844, height: 325))
    }

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

/// A small filesystem picker embedded in the same page; no NSOpenPanel or sheet.
private final class InlineFileBrowser: SurfaceView {
    enum Mode { case torrents, directory, browse }
    private let mode: Mode
    private let onSelect: ([URL]) -> Void
    private let path = NSTextField()
    private let folderName = NSTextField()
    private let message = Titanium.label(size: 10, color: Titanium.muted)
    private let list = FlowListView(frame: NSRect(x: 28, y: 181, width: 844, height: 242))
    private var directory: URL
    private var entries: [(url: URL, isDirectory: Bool)] = []

    init(frame: NSRect, mode: Mode, initial: URL, onSelect: @escaping ([URL]) -> Void, onCancel: @escaping () -> Void) {
        self.mode = mode
        self.directory = FileManager.default.homeDirectoryForCurrentUser
        self.onSelect = onSelect
        super.init(frame: frame, color: Titanium.panel)
        let back = ActionButton("返回", symbol: "arrow.left", frame: NSRect(x: 24, y: 16, width: 112, height: 28), action: onCancel)
        back.restingColor = Titanium.background
        addSubview(back)
        let title = Titanium.label(mode == .browse ? "保存位置" : mode == .directory ? "选择保存目录" : "选择种子文件", size: 20)
        title.frame = NSRect(x: 28, y: 61, width: 844, height: 32)
        addSubview(title)
        path.frame = NSRect(x: 28, y: 104, width: 720, height: 28)
        path.font = Titanium.font(12)
        path.placeholderString = "输入文件夹路径，按回车前往"
        path.target = self
        path.action = #selector(goToPath)
        path.setAccessibilityLabel("浏览文件夹路径")
        addSubview(path)
        let go = ActionButton("前往", frame: NSRect(x: 760, y: 104, width: 112, height: 28)) { [weak self] in self?.goToPath() }
        go.restingColor = Titanium.background
        addSubview(go)
        addSubview(ActionButton("上一级", symbol: "arrow.up", frame: NSRect(x: 28, y: 143, width: 112, height: 28)) { [weak self] in
            guard let self else { return }; self.navigate(self.directory.deletingLastPathComponent())
        })
        addSubview(ActionButton("个人目录", symbol: "house", frame: NSRect(x: 154, y: 143, width: 126, height: 28)) { [weak self] in
            self?.navigate(FileManager.default.homeDirectoryForCurrentUser)
        })
        list.allowsMultipleSelection = mode == .torrents
        list.onDoubleClick = { [weak self] in self?.openSelection() }
        addSubview(list)
        folderName.frame = NSRect(x: 28, y: 438, width: 280, height: 26)
        folderName.font = Titanium.font(11)
        folderName.placeholderString = "新文件夹名称"
        folderName.setAccessibilityLabel("新文件夹名称")
        if mode != .browse {
            addSubview(folderName)
            addSubview(ActionButton("新建文件夹", symbol: "folder.badge.plus", frame: NSRect(x: 320, y: 437, width: 154, height: 28)) { [weak self] in self?.createFolder() })
        }
        message.frame = NSRect(x: 28, y: 467, width: 844, height: 20)
        addSubview(message)
        let select = ActionButton(mode == .browse ? "查看所选项目" : mode == .directory ? "选择此文件夹" : "选择种子文件", frame: NSRect(x: 710, y: 493, width: 162, height: 32)) { [weak self] in self?.accept() }
        select.active = true
        addSubview(select)
        navigate(directory)
        if initial.standardizedFileURL != directory.standardizedFileURL { navigate(initial) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    private func navigate(_ url: URL) {
        do {
            let resolved = url.standardizedFileURL
            let contents = try FileManager.default.contentsOfDirectory(at: resolved,
                includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
            let values = try contents.compactMap { url -> (url: URL, isDirectory: Bool)? in
                let directory = try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
                guard directory || mode == .browse || (mode == .torrents && url.pathExtension.lowercased() == "torrent") else { return nil }
                return (url, directory)
            }.sorted {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                return $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending
            }
            directory = resolved
            entries = values
            path.stringValue = resolved.path
            path.toolTip = resolved.path
            list.strings = values.map { ($0.isDirectory ? "▸  " : "    ") + $0.url.lastPathComponent }
            message.stringValue = values.isEmpty ? "文件夹为空；可前往上一级或输入其他路径。" : "双击文件夹进入；也可直接输入路径。"
            message.textColor = Titanium.muted
        } catch {
            message.stringValue = error.localizedDescription
            message.toolTip = error.localizedDescription
            message.textColor = Titanium.red
        }
    }

    @objc private func goToPath() {
        let text = path.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let expanded = (text as NSString).expandingTildeInPath
        let url = expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : directory.appendingPathComponent(expanded)
        navigate(url)
    }

    private func openSelection() {
        guard let index = list.selectedIndexes.first, entries.indices.contains(index) else { return }
        let entry = entries[index]
        if entry.isDirectory { navigate(entry.url) }
        else if mode == .browse { showFileInfo(entry.url) }
        else { onSelect([entry.url]) }
    }

    private func accept() {
        let selected = list.selectedIndexes.compactMap { entries.indices.contains($0) ? entries[$0] : nil }
        if mode == .browse {
            openSelection()
        } else if mode == .directory {
            onSelect([selected.first(where: { $0.isDirectory })?.url ?? directory])
        } else {
            let files = selected.filter { !$0.isDirectory }.map(\.url)
            if !files.isEmpty { onSelect(files) }
            else if let folder = selected.first(where: { $0.isDirectory }) { navigate(folder.url) }
            else { message.stringValue = "请选择一个或多个 .torrent 文件。"; message.textColor = Titanium.red }
        }
    }

    private func showFileInfo(_ url: URL) {
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            message.stringValue = "\(url.lastPathComponent) · \(Titanium.bytes(Int64(values.fileSize ?? 0)))"
            message.toolTip = url.path
            message.textColor = Titanium.text
        } catch { message.stringValue = error.localizedDescription; message.textColor = Titanium.red }
    }

    private func createFolder() {
        let name = folderName.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else {
            message.stringValue = "请输入不含斜杠的有效文件夹名称。"; message.textColor = Titanium.red; return
        }
        do {
            let created = directory.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: created, withIntermediateDirectories: false)
            folderName.stringValue = ""
            navigate(created)
        } catch { message.stringValue = error.localizedDescription; message.textColor = Titanium.red }
    }
}

private final class FlowListView: NSScrollView, NSTableViewDataSource, NSTableViewDelegate {
    private let table = NSTableView()
    var strings: [String] = [] { didSet { table.deselectAll(nil); table.reloadData() } }
    var onSelection: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    var selectedIndexes: IndexSet { table.selectedRowIndexes }
    var allowsMultipleSelection: Bool {
        get { table.allowsMultipleSelection }
        set { table.allowsMultipleSelection = newValue }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        borderType = .noBorder
        hasVerticalScroller = true
        autohidesScrollers = true
        drawsBackground = true
        backgroundColor = Titanium.background
        table.frame = NSRect(origin: .zero, size: frame.size)
        table.autoresizingMask = [.width]
        table.headerView = nil
        table.rowHeight = 27
        table.intercellSpacing = .zero
        table.backgroundColor = Titanium.background
        table.usesAlternatingRowBackgroundColors = true
        table.allowsEmptySelection = true
        table.style = .plain
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("item"))
        column.width = frame.width - 10
        table.addTableColumn(column)
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openRow)
        documentView = table
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    func select(_ index: Int) { table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false); onSelection?() }
    func numberOfRows(in tableView: NSTableView) -> Int { strings.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let text = Titanium.label(strings[row], size: 12)
        text.frame = NSRect(x: 8, y: 3, width: bounds.width - 18, height: 21)
        text.toolTip = strings[row]
        let cell = SurfaceView()
        cell.addSubview(text)
        return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) { onSelection?() }
    @objc private func openRow() { onDoubleClick?() }
}
