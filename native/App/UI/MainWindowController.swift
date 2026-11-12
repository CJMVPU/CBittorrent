import AppKit

/// AppKit owns the window and dense table; all transfer actions go through AppStore.
final class MainWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource,
                                  NSTableViewDelegate, NSSearchFieldDelegate {
    private let store: AppStore
    private let surface = SurfaceView(frame: NSRect(x: 0, y: 0, width: 1000, height: 680), color: Titanium.panel)
    private let toolbar = SurfaceView(frame: NSRect(x: 0, y: 32, width: 1000, height: 34), color: Titanium.panel)
    private let scrollView = NSScrollView(frame: NSRect(x: 6, y: 66, width: 988, height: 587))
    private let table = NSTableView()
    private let search = NSSearchField()
    private let emptyLabel = Titanium.label("添加种子文件或磁力链接，开始第一次传输。", size: 13, color: Titanium.muted, alignment: .center)
    private var filterButtons: [(TaskFilter, ActionButton)] = []
    private var selectionButtons: [ActionButton] = []
    private let transfersButton = ActionButton("传输", symbol: "square.stack")
    private let settingsButton = ActionButton("设置", symbol: "slider.horizontal.3")
    private let inspectorButton = ActionButton("详情", symbol: "sidebar.right")
    private var inspector: InspectorView!
    private var settingsView: SettingsView!
    private var showingSettings = false
    private var inspectorVisible = true
    private var refreshingSelection = false
    private var torrents: [TorrentSnapshot] = []
    private var statusLabels: [NSTextField] = []
    private var lastDiskCheck = Date.distantPast
    private var diskStatus = ""

    init(store: AppStore) {
        self.store = store
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 680),
                              styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "CBittorrent"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = Titanium.panel
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenNone]
        window.tabbingMode = .disallowed
        window.hasShadow = true
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = surface
        window.contentMinSize = NSSize(width: 1000, height: 680)
        window.contentMaxSize = NSSize(width: 1000, height: 680)
        window.delegate = self
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(type)?.isHidden = true
        }
        window.center()
        buildTitlebar()
        buildToolbar()
        buildTable()
        buildStatusbar()
        inspector = InspectorView(store: store) { [weak self] in self?.toggleInspector() }
        inspector.frame = NSRect(x: 738, y: 74, width: 248, height: 571)
        surface.addSubview(inspector)
        settingsView = SettingsView(store: store) { [weak self] in self?.showTransfers() }
        settingsView.frame = NSRect(x: 0, y: 32, width: 1000, height: 621)
        settingsView.isHidden = true
        surface.addSubview(settingsView)
        store.onChange = { [weak self] in self?.refresh() }
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func showSettings() {
        if !showingSettings { settingsView.reload() }
        showingSettings = true
        settingsView.isHidden = false
        toolbar.isHidden = true
        scrollView.isHidden = true
        emptyLabel.isHidden = true
        inspector.isHidden = true
        transfersButton.active = false
        settingsButton.active = true
    }

    func showTransfers() {
        showingSettings = false
        settingsView.isHidden = true
        toolbar.isHidden = false
        scrollView.isHidden = false
        inspector.isHidden = !inspectorVisible
        transfersButton.active = true
        settingsButton.active = false
        refresh()
    }

    func focusSearch() {
        showTransfers()
        window?.makeFirstResponder(search)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if store.settings.closeKeepsTransfers {
            sender.orderOut(nil)
        } else {
            NSApp.terminate(nil)
        }
        return false
    }

    func windowShouldZoom(_ window: NSWindow, toFrame newFrame: NSRect) -> Bool { false }

    private func buildTitlebar() {
        let titlebar = TitlebarView(frame: NSRect(x: 0, y: 0, width: 1000, height: 32), color: Titanium.chrome)
        surface.addSubview(titlebar)
        let capsule = SurfaceView(frame: NSRect(x: 12, y: 5, width: 54, height: 22), color: NSColor(hex: 0xE5E8ED), radius: 11)
        titlebar.addSubview(capsule)
        let close = ActionButton(symbol: "xmark", frame: NSRect(x: 1, y: 1, width: 26, height: 20)) { [weak self] in self?.window?.performClose(nil) }
        close.tint = NSColor(hex: 0x9D707B)
        close.hoverColor = NSColor(hex: 0xE8CED3)
        close.layer?.cornerRadius = 10
        close.toolTip = "关闭窗口"
        close.setAccessibilityLabel("关闭窗口")
        capsule.addSubview(close)
        let minimize = ActionButton(symbol: "minus", frame: NSRect(x: 27, y: 1, width: 26, height: 20)) { [weak self] in self?.window?.miniaturize(nil) }
        minimize.layer?.cornerRadius = 10
        minimize.toolTip = "最小化"
        minimize.setAccessibilityLabel("最小化")
        capsule.addSubview(minimize)
        let mark = SurfaceView(frame: NSRect(x: 79, y: 7, width: 18, height: 18), color: Titanium.accent, radius: 5)
        let glyph = NSImageView(frame: NSRect(x: 3, y: 3, width: 12, height: 12))
        glyph.image = NSImage(systemSymbolName: "arrow.down.to.line", accessibilityDescription: nil)
        glyph.contentTintColor = .white
        mark.addSubview(glyph)
        titlebar.addSubview(mark)
        let brand = Titanium.label("CBittorrent", size: 11)
        brand.frame = NSRect(x: 103, y: 8, width: 140, height: 18)
        titlebar.addSubview(brand)
        transfersButton.frame = NSRect(x: 852, y: 5, width: 65, height: 22)
        transfersButton.active = true
        transfersButton.handler = { [weak self] in self?.showTransfers() }
        titlebar.addSubview(transfersButton)
        settingsButton.frame = NSRect(x: 922, y: 5, width: 65, height: 22)
        settingsButton.handler = { [weak self] in self?.showSettings() }
        titlebar.addSubview(settingsButton)
    }

    private func buildToolbar() {
        surface.addSubview(toolbar)
        var x: CGFloat = 13
        for filter in TaskFilter.allCases {
            let width: CGFloat = filter == .all ? 91 : 79
            let button = ActionButton(filter.title, frame: NSRect(x: x, y: 5, width: width, height: 24)) { [weak self] in self?.store.setFilter(filter) }
            button.font = Titanium.font(11)
            toolbar.addSubview(button)
            filterButtons.append((filter, button))
            x += width + 3
        }
        x += 10
        let add = ActionButton("添加", symbol: "plus", frame: NSRect(x: x, y: 5, width: 54, height: 24)) { [weak store] in store?.addTorrentPrompt() }
        add.active = true
        add.toolTip = "添加种子文件或磁力链接 (⌘O)"
        toolbar.addSubview(add)
        x += 62
        let actions: [(String, String, () -> Void)] = [
            ("play", "开始所选任务", { [weak store] in store?.startSelected() }),
            ("pause", "停止所选任务", { [weak store] in store?.pauseSelected() }),
            ("trash", "移除所选任务", { [weak store] in store?.removeSelected() })
        ]
        for (symbol, label, handler) in actions {
            let button = ActionButton(symbol: symbol, frame: NSRect(x: x, y: 5, width: 27, height: 24), action: handler)
            button.toolTip = label
            button.setAccessibilityLabel(label)
            toolbar.addSubview(button)
            selectionButtons.append(button)
            x += 30
        }
        let more = ActionButton(symbol: "ellipsis", frame: NSRect(x: x + 3, y: 5, width: 27, height: 24))
        more.toolTip = "更多任务操作"
        more.setAccessibilityLabel("更多任务操作")
        more.handler = { [weak self, weak more] in
            guard let self, let more else { return }
            self.showMore(from: more)
        }
        toolbar.addSubview(more)
        selectionButtons.append(more)
        inspectorButton.frame = NSRect(x: 742, y: 5, width: 66, height: 24)
        inspectorButton.active = true
        inspectorButton.handler = { [weak self] in self?.toggleInspector() }
        toolbar.addSubview(inspectorButton)
        search.frame = NSRect(x: 818, y: 5, width: 169, height: 24)
        search.placeholderString = "搜索任务"
        search.font = Titanium.font(11)
        search.focusRingType = .exterior
        search.delegate = self
        search.sendsSearchStringImmediately = true
        search.setAccessibilityLabel("搜索任务")
        toolbar.addSubview(search)
    }

    private func buildTable() {
        table.backgroundColor = Titanium.panel
        table.headerView = QuietHeaderView(frame: NSRect(x: 0, y: 0, width: 986, height: 29))
        table.rowHeight = 35
        table.intercellSpacing = .zero
        table.gridStyleMask = []
        table.usesAlternatingRowBackgroundColors = false
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.allowsColumnReordering = false
        table.allowsColumnResizing = false
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.selectionHighlightStyle = .regular
        table.style = .plain
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(revealSelection)
        let titles = ["名称", "进度", "状态", "剩余时间", "↓ 下载 /s", "↑ 上传 /s", "分享率", "大小"]
        let widths: [CGFloat] = [270, 116, 80, 110, 105, 105, 80, 120]
        for (index, title) in titles.enumerated() {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(String(index)))
            column.width = widths[index]
            column.minWidth = widths[index]
            column.maxWidth = widths[index]
            column.resizingMask = []
            column.headerCell = QuietHeaderCell(textCell: title)
            column.headerCell.alignment = index >= 3 ? .right : .left
            table.addTableColumn(column)
        }
        table.frame = NSRect(x: 0, y: 0, width: 986, height: 558)
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = Titanium.panel
        scrollView.documentView = table
        surface.addSubview(scrollView)
        emptyLabel.frame = NSRect(x: 50, y: 282, width: 650, height: 26)
        surface.addSubview(emptyLabel)
    }

    private func buildStatusbar() {
        let statusbar = SurfaceView(frame: NSRect(x: 0, y: 653, width: 1000, height: 27), color: Titanium.chrome)
        surface.addSubview(statusbar)
        let widths: [CGFloat] = [190, 116, 109, 109, 210, 110, 130]
        var x: CGFloat = 13
        for width in widths {
            let label = Titanium.label(size: 10, color: Titanium.muted)
            label.frame = NSRect(x: x, y: 6, width: width - 8, height: 16)
            statusbar.addSubview(label)
            statusLabels.append(label)
            x += width
        }
    }

    private func toggleInspector() {
        inspectorVisible.toggle()
        inspector.isHidden = !inspectorVisible || showingSettings
        inspectorButton.active = inspectorVisible
    }

    private func count(_ filter: TaskFilter) -> Int {
        store.snapshot.torrents.filter { torrent in
            switch filter {
            case .all: return true
            case .downloading: return ["downloading", "metadata"].contains(torrent.state)
            case .seeding: return torrent.state == "seeding"
            case .paused: return torrent.state == "paused"
            case .queued: return torrent.state == "queued"
            }
        }.count
    }

    private func refresh() {
        let previousIDs = torrents.map(\.id)
        torrents = store.filteredTorrents
        for (filter, button) in filterButtons {
            button.setTitle("\(filter.title) \(count(filter))")
            button.active = store.filter == filter
        }
        selectionButtons.forEach { $0.isEnabled = !store.selectedIDs.isEmpty }
        if previousIDs != torrents.map(\.id) {
            refreshingSelection = true
            table.reloadData()
            refreshingSelection = false
        } else {
            let visibleRows = table.rows(in: scrollView.contentView.documentVisibleRect)
            if visibleRows.location != NSNotFound {
                for row in visibleRows.location..<NSMaxRange(visibleRows) where row < torrents.count {
                    for column in 0..<8 {
                        if let view = table.view(atColumn: column, row: row, makeIfNecessary: false) {
                            updateCell(view, column: column, torrent: torrents[row])
                        }
                    }
                }
            }
        }
        let indexes = IndexSet(torrents.indices.filter { store.selectedIDs.contains(torrents[$0].id) })
        if indexes != table.selectedRowIndexes {
            refreshingSelection = true
            table.selectRowIndexes(indexes, byExtendingSelection: false)
            refreshingSelection = false
        }
        emptyLabel.isHidden = showingSettings || !torrents.isEmpty
        emptyLabel.stringValue = store.snapshot.torrents.isEmpty
            ? "添加种子文件或磁力链接，开始第一次传输。" : "没有匹配的任务"
        inspector.update(store.selectedTorrent)
        updateStatus()
    }

    private func updateStatus() {
        let snapshot = store.snapshot
        let selectedFileCount = snapshot.torrents.filter { store.selectedIDs.contains($0.id) }.reduce(0) { $0 + $1.files.count }
        if Date().timeIntervalSince(lastDiskCheck) > 15 {
            lastDiskCheck = Date()
            if let attributes = try? FileManager.default.attributesOfFileSystem(forPath: store.settings.downloadPath),
               let bytes = attributes[.systemFreeSize] as? NSNumber {
                diskStatus = "\(Titanium.bytes(bytes.int64Value)) 可用"
            } else { diskStatus = "磁盘空间不可用" }
        }
        let values = [
            "\(torrents.count) 个任务 · 选中 \(table.selectedRowIndexes.count) · \(selectedFileCount) 文件",
            "\(count(.downloading)) 下载 · \(count(.seeding)) 做种",
            "↓ \(Titanium.bytes(snapshot.downloadRate))/s",
            "↑ \(Titanium.bytes(snapshot.uploadRate))/s",
            "会话 ↓ \(Titanium.bytes(snapshot.totalDownloaded)) ↑ \(Titanium.bytes(snapshot.totalUploaded))",
            "DHT \(snapshot.dhtNodes)", diskStatus
        ]
        for (label, value) in zip(statusLabels, values) {
            label.stringValue = value
            label.toolTip = value
        }
        statusLabels[4].toolTip = "本次会话：下载 \(Titanium.bytes(snapshot.totalDownloaded)) · 上传 \(Titanium.bytes(snapshot.totalUploaded))"
        statusLabels[5].toolTip = "DHT 节点：\(snapshot.dhtNodes) · 监听端口：\(snapshot.listenPort)"
        if let error = snapshot.errors.last {
            statusLabels[5].stringValue = "传输引擎有提示"
            statusLabels[5].textColor = Titanium.orange
            statusLabels[5].toolTip = error
        } else { statusLabels[5].textColor = Titanium.muted }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { torrents.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { TransferRowView() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, row < torrents.count, let column = Int(tableColumn.identifier.rawValue) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("cell-\(column)")
        let view: NSView
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) {
            view = reused
        } else {
            switch column {
            case 0: view = MarqueeNameView()
            case 1: view = ProgressCell()
            default: view = ValueCell()
            }
            view.identifier = identifier
        }
        updateCell(view, column: column, torrent: torrents[row])
        return view
    }

    private func updateCell(_ view: NSView, column: Int, torrent: TorrentSnapshot) {
        if let name = view as? MarqueeNameView { name.update(torrent.name); return }
        if let progress = view as? ProgressCell { progress.update(torrent); return }
        guard let cell = view as? ValueCell else { return }
        cell.label.alignment = column >= 3 ? .right : .left
        cell.label.font = Titanium.font(column == 2 ? 11 : 12)
        cell.label.textColor = column == 2 ? Titanium.stateColor(torrent.state) : Titanium.text
        let text: String
        switch column {
        case 2: text = "· \(Titanium.state(torrent.state))"
        case 3: text = Titanium.duration(torrent.eta)
        case 4: text = Titanium.rate(torrent.downloadRate)
        case 5: text = Titanium.rate(torrent.uploadRate)
        case 6: text = String(format: "%.2f", torrent.ratio)
        case 7: text = Titanium.bytes(torrent.totalSize)
        default: text = ""
        }
        cell.label.stringValue = text
        cell.toolTip = text
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !refreshingSelection else { return }
        store.select(ids: Set(table.selectedRowIndexes.compactMap { row in
            torrents.indices.contains(row) ? torrents[row].id : nil
        }))
    }

    func controlTextDidChange(_ obj: Notification) {
        guard obj.object as? NSSearchField === search else { return }
        store.setSearch(search.stringValue)
    }

    private func showMore(from button: NSView) {
        let menu = NSMenu()
        for (title, action) in [("在访达中显示", #selector(revealSelection)),
                                ("查看文件", #selector(showFiles)), ("查看 Tracker", #selector(showTrackers))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 2), in: button)
    }

    @objc private func revealSelection() { store.revealSelected() }
    @objc private func showFiles() { store.showFiles() }
    @objc private func showTrackers() { store.showTrackers() }
}
