import AppKit

/// AppKit owns the window and dense table; all transfer actions go through AppStore.
final class MainWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource,
                                  NSTableViewDelegate, NSSearchFieldDelegate {
    private let store: AppStore
    private let surface = SurfaceView(frame: NSRect(x: 0, y: 0, width: 900, height: 600), color: Titanium.panel)
    private let scrollView = NSScrollView(frame: NSRect(x: 6, y: 32, width: 888, height: 541))
    private let table = StripedTransferTableView()
    private let search = NSSearchField()
    private let emptyLabel = Titanium.label("添加种子文件或磁力链接，开始第一次传输。", size: 13, color: Titanium.muted, alignment: .center)
    private let filterPicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private var selectionButtons: [ActionButton] = []
    private let settingsButton = ActionButton("设置", symbol: "slider.horizontal.3")
    private var settingsView: SettingsView!
    private var showingSettings = false
    private var flows: [InWindowFlowView] = []
    private var flowTokens: [UUID] = []
    private var refreshingSelection = false
    private var torrents: [TorrentSnapshot] = []
    private var statusLabels: [NSTextField] = []
    private var lastDiskCheck = Date.distantPast
    private var diskStatus = ""

    init(store: AppStore) {
        self.store = store
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
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
        window.contentMinSize = NSSize(width: 900, height: 600)
        window.contentMaxSize = NSSize(width: 900, height: 600)
        window.delegate = self
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(type)?.isHidden = true
        }
        window.center()
        buildTitlebar()
        buildTable()
        buildStatusbar()
        settingsView = SettingsView(store: store) { [weak self] in self?.showTransfers() }
        settingsView.frame = NSRect(x: 0, y: 32, width: 900, height: 541)
        settingsView.isHidden = true
        surface.addSubview(settingsView)
        store.onPresent = { [weak self] request in self?.present(request) }
        store.onChange = { [weak self] in self?.refresh() }
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    private func clearFlows() {
        flows.forEach { $0.removeFromSuperview() }
        flows.removeAll()
        flowTokens.removeAll()
    }

    func present(_ request: InWindowRequest) {
        window?.makeFirstResponder(nil)
        flows.last?.isHidden = true
        let token = UUID()
        let page = InWindowFlowView(request: request, store: store) { [weak self] in
            guard let self, self.flowTokens.last == token else { return }
            self.flowTokens.removeLast()
            self.flows.popLast()?.removeFromSuperview()
            if let previous = self.flows.last { previous.isHidden = false }
            else if self.showingSettings { self.settingsView.isHidden = false }
            else { self.scrollView.isHidden = false }
            self.refresh()
        }
        page.frame = NSRect(x: 0, y: 32, width: 900, height: 541)
        flows.append(page)
        flowTokens.append(token)
        surface.addSubview(page)
        settingsView.isHidden = true
        scrollView.isHidden = true
        emptyLabel.isHidden = true
        selectionButtons.forEach { $0.isEnabled = false }
        NSApp.unhide(nil)
        window?.deminiaturize(nil)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func showSettings() {
        clearFlows()
        if !showingSettings { settingsView.reload() }
        showingSettings = true
        settingsView.isHidden = false
        scrollView.isHidden = true
        emptyLabel.isHidden = true
        settingsButton.active = true
        selectionButtons.forEach { $0.isEnabled = false }
    }

    func showTransfers() {
        clearFlows()
        showingSettings = false
        settingsView.isHidden = true
        scrollView.isHidden = false
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
        let titlebar = TitlebarView(frame: NSRect(x: 0, y: 0, width: 900, height: 32), color: Titanium.chrome)
        surface.addSubview(titlebar)
        titlebar.addSubview(WindowControlButtons(frame: NSRect(x: 12, y: 4, width: 50, height: 24)))
        let mark = NSImageView(frame: NSRect(x: 78, y: 2, width: 28, height: 28))
        if let iconURL = Bundle.main.url(forResource: "CBittorrent", withExtension: "icns") {
            mark.image = NSImage(contentsOf: iconURL)
        }
        mark.setAccessibilityLabel("CBittorrent")
        titlebar.addSubview(mark)
        buildTransferControls(in: titlebar)
        settingsButton.frame = NSRect(x: 822, y: 5, width: 65, height: 22)
        settingsButton.handler = { [weak self] in self?.showSettings() }
        titlebar.addSubview(settingsButton)
    }

    private func buildTransferControls(in titlebar: NSView) {
        filterPicker.frame = NSRect(x: 120, y: 4, width: 128, height: 24)
        filterPicker.font = Titanium.font(11)
        filterPicker.controlSize = .small
        filterPicker.isBordered = false
        filterPicker.wantsLayer = true
        filterPicker.layer?.cornerRadius = 6
        filterPicker.layer?.backgroundColor = Titanium.panel.withAlphaComponent(0.65).cgColor
        filterPicker.addItems(withTitles: TaskFilter.allCases.map(\.title))
        filterPicker.target = self
        filterPicker.action = #selector(filterChanged)
        filterPicker.setAccessibilityLabel("任务状态筛选")
        filterPicker.toolTip = "按任务状态筛选"
        titlebar.addSubview(filterPicker)

        search.cell = CenteredSearchCell(textCell: "")
        search.isBezeled = true
        search.bezelStyle = .roundedBezel
        search.drawsBackground = true
        search.isEditable = true
        search.isSelectable = true
        search.frame = NSRect(x: 258, y: 4, width: 324, height: 24)
        search.placeholderString = "搜索任务"
        search.font = Titanium.font(11)
        search.focusRingType = .none
        search.delegate = self
        search.sendsSearchStringImmediately = true
        search.setAccessibilityLabel("搜索任务")
        titlebar.addSubview(search)

        let add = ActionButton("添加", symbol: "plus", frame: NSRect(x: 592, y: 4, width: 60, height: 24)) { [weak store] in store?.addTorrentPrompt() }
        add.active = true
        add.toolTip = "添加种子文件或磁力链接 (⌘O)"
        titlebar.addSubview(add)
        var x: CGFloat = 661
        let actions: [(String, String, () -> Void)] = [
            ("play", "开始所选任务", { [weak store] in store?.startSelected() }),
            ("pause", "停止所选任务", { [weak store] in store?.pauseSelected() }),
            ("trash", "移除所选任务", { [weak store] in store?.removeSelected() })
        ]
        for (symbol, label, handler) in actions {
            let button = ActionButton(symbol: symbol, frame: NSRect(x: x, y: 4, width: 27, height: 24), action: handler)
            button.toolTip = label
            button.setAccessibilityLabel(label)
            titlebar.addSubview(button)
            selectionButtons.append(button)
            x += 30
        }
        let more = ActionButton(symbol: "ellipsis", frame: NSRect(x: x, y: 4, width: 27, height: 24))
        more.toolTip = "更多任务操作"
        more.setAccessibilityLabel("更多任务操作")
        more.handler = { [weak self, weak more] in
            guard let self, let more else { return }
            self.showMore(from: more)
        }
        titlebar.addSubview(more)
        selectionButtons.append(more)
    }

    @objc private func filterChanged() {
        guard TaskFilter.allCases.indices.contains(filterPicker.indexOfSelectedItem) else { return }
        let filter = TaskFilter.allCases[filterPicker.indexOfSelectedItem]
        showTransfers()
        store.setFilter(filter)
    }

    private func buildTable() {
        table.backgroundColor = Titanium.panel
        table.headerView = QuietHeaderView(frame: NSRect(x: 0, y: 0, width: 886, height: 25))
        table.rowHeight = 24
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
        let widths: [CGFloat] = [230, 106, 72, 98, 94, 94, 74, 118]
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
        table.frame = NSRect(x: 0, y: 0, width: 886, height: 516)
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = Titanium.panel
        scrollView.documentView = table
        surface.addSubview(scrollView)
        emptyLabel.frame = NSRect(x: 30, y: 285, width: 840, height: 26)
        surface.addSubview(emptyLabel)
    }

    private func buildStatusbar() {
        let statusbar = SurfaceView(frame: NSRect(x: 0, y: 573, width: 900, height: 27), color: Titanium.chrome)
        surface.addSubview(statusbar)
        let widths: [CGFloat] = [120, 90, 100, 100, 220, 90, 154]
        var x: CGFloat = 13
        for width in widths {
            let label = Titanium.label(size: 10, color: Titanium.muted)
            label.frame = NSRect(x: x, y: 6, width: width - 8, height: 16)
            statusbar.addSubview(label)
            statusLabels.append(label)
            x += width
        }
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
        for (index, filter) in TaskFilter.allCases.enumerated() {
            filterPicker.item(at: index)?.title = "\(filter.title) · \(count(filter))"
        }
        if let index = TaskFilter.allCases.firstIndex(of: store.filter) { filterPicker.selectItem(at: index) }
        selectionButtons.forEach { $0.isEnabled = !showingSettings && flows.isEmpty && !store.selectedIDs.isEmpty }
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
        emptyLabel.isHidden = showingSettings || !flows.isEmpty || !torrents.isEmpty
        emptyLabel.stringValue = store.snapshot.torrents.isEmpty
            ? "添加种子文件或磁力链接，开始第一次传输。" : "没有匹配的任务"
        updateStatus()
    }

    private func updateStatus() {
        let snapshot = store.snapshot
        let connections = snapshot.torrents.reduce(0) { $0 + $1.peers }
        if Date().timeIntervalSince(lastDiskCheck) > 15 {
            lastDiskCheck = Date()
            if let attributes = try? FileManager.default.attributesOfFileSystem(forPath: store.settings.downloadPath),
               let bytes = attributes[.systemFreeSize] as? NSNumber {
                diskStatus = "\(Titanium.bytes(bytes.int64Value)) 可用"
            } else { diskStatus = "磁盘空间不可用" }
        }
        let values = [
            "\(count(.downloading)) 下载 · \(count(.seeding)) 做种",
            "连接 \(connections)",
            "↓ \(Titanium.bytes(snapshot.downloadRate))/s",
            "↑ \(Titanium.bytes(snapshot.uploadRate))/s",
            "会话 ↓ \(Titanium.bytes(snapshot.totalDownloaded)) ↑ \(Titanium.bytes(snapshot.totalUploaded))",
            "DHT \(snapshot.dhtNodes)", diskStatus
        ]
        for (label, value) in zip(statusLabels, values) {
            label.stringValue = value
            label.toolTip = value
        }
        statusLabels[1].toolTip = "当前所有任务的已连接 Peer 总数：\(connections)"
        statusLabels[4].toolTip = "本次会话：下载 \(Titanium.bytes(snapshot.totalDownloaded)) · 上传 \(Titanium.bytes(snapshot.totalUploaded))"
        statusLabels[5].toolTip = "DHT 节点：\(snapshot.dhtNodes) · 监听端口：\(snapshot.listenPort)"
        if let error = snapshot.errors.last {
            statusLabels[5].stringValue = "传输引擎有提示"
            statusLabels[5].textColor = Titanium.orange
            statusLabels[5].toolTip = error
        } else { statusLabels[5].textColor = Titanium.muted }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { torrents.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = TransferRowView()
        view.alternate = row % 2 == 1
        return view
    }

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
        if showingSettings || !flows.isEmpty { showTransfers() }
        store.setSearch(search.stringValue)
    }

    private func showMore(from button: NSView) {
        let menu = NSMenu()
        for (title, action) in [("打开保存位置", #selector(revealSelection)),
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
