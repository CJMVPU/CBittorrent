import AppKit

/// Sections keep their controls alive so switching pages never discards an edit.
final class SettingsView: SurfaceView, NSTextFieldDelegate, NSTextViewDelegate {
    private enum Page: Int, CaseIterable {
        case general, downloads, connection, speed, bittorrent, trackers, advanced
        var title: String { ["通用", "下载", "连接", "速度", "BitTorrent", "Tracker", "高级"][rawValue] }
        var symbol: String { ["slider.horizontal.3", "arrow.down.to.line", "network", "speedometer", "point.3.connected.trianglepath.dotted", "link", "gearshape.2"][rawValue] }
        var subtitle: String {
            ["窗口行为与完成提醒", "保存位置与新任务的默认行为", "监听端口、端口映射与连接数量", "全局传输速度与上传并发", "节点发现、加密、任务队列与做种目标", "默认地址列表与任务自动追加", "传输协议与代理连接"][rawValue]
        }
    }

    private let store: AppStore
    private var draft: AppSettings
    private var hasUnsavedChanges = false
    private var saving = false
    private var currentPage = Page.general
    private var pages: [Page: SurfaceView] = [:]
    private var pageButtons: [Page: ActionButton] = [:]
    private var scrollPositions: [Page: NSPoint] = [:]
    private let heading = Titanium.label(size: 22)
    private let subtitle = Titanium.label(size: 11, color: Titanium.muted)
    private let feedback = Titanium.label(size: 11, color: Titanium.muted)
    private let scrollView = NSScrollView()
    private let saveButton = ActionButton("保存设置", symbol: "checkmark")
    private let resetButton = ActionButton("还原更改", symbol: "arrow.counterclockwise")
    private var readers: [() throws -> Void] = []
    private var writers: [(AppSettings) -> Void] = []
    private var actions: [ObjectIdentifier: () -> Void] = [:]
    private var editableControls: [NSControl] = []
    private var queueControls: [NSControl] = []
    private var proxyControls: [NSControl] = []
    private var pathField: NSTextField?
    private var trackerEditor: NSTextView?
    private var applyTrackersButton: ActionButton?
    private let inputColumnX: CGFloat = 220
    private let inputWidth: CGFloat = 260
    private let documentWidth: CGFloat = 684
    private let viewportHeight: CGFloat = 375

    init(store: AppStore, onBack: @escaping () -> Void) {
        self.store = store
        draft = store.settings
        super.init(color: Titanium.panel)
        let sidebar = SurfaceView(frame: NSRect(x: 0, y: 0, width: 156, height: 541), color: Titanium.background)
        addSubview(sidebar)
        let back = ActionButton("返回传输", symbol: "arrow.left", frame: NSRect(x: 16, y: 16, width: 124, height: 32), action: onBack)
        back.alignment = .center
        back.font = Titanium.font(12)
        back.setTitle("返回传输")
        back.restingColor = Titanium.chrome
        back.tint = Titanium.text
        sidebar.addSubview(back)
        for page in Page.allCases {
            let button = ActionButton(page.title, symbol: page.symbol,
                                      frame: NSRect(x: 16, y: 74 + page.rawValue * 42, width: 124, height: 32)) { [weak self] in
                self?.show(page)
            }
            button.selectionChangesBackground = false
            button.hoverColor = .clear
            button.alignment = .left
            button.font = Titanium.font(12)
            button.setTitle(page.title)
            button.layer?.cornerRadius = 8
            sidebar.addSubview(button)
            pageButtons[page] = button
        }
        heading.frame = NSRect(x: 180, y: 18, width: 700, height: 32)
        subtitle.frame = NSRect(x: 180, y: 55, width: 700, height: 21)
        addSubview(heading)
        addSubview(subtitle)
        scrollView.frame = NSRect(x: 180, y: 92, width: 700, height: viewportHeight)
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        addSubview(scrollView)
        feedback.frame = NSRect(x: 180, y: 486, width: 418, height: 40)
        feedback.maximumNumberOfLines = 2
        feedback.cell?.wraps = true
        addSubview(feedback)
        resetButton.frame = NSRect(x: 612, y: 490, width: 122, height: 32)
        resetButton.restingColor = Titanium.background
        resetButton.handler = { [weak self] in self?.restoreSavedValues() }
        resetButton.toolTip = "放弃尚未保存的修改，恢复当前已保存设置"
        addSubview(resetButton)
        saveButton.frame = NSRect(x: 746, y: 490, width: 134, height: 32)
        saveButton.active = true
        saveButton.handler = { [weak self] in self?.save() }
        addSubview(saveButton)
        buildPages()
        restoreSavedValues()
        show(.general)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func reload() {
        // Returning from transfers preserves an unfinished settings draft.
        guard !hasUnsavedChanges && !saving else { return }
        restoreSavedValues()
    }

    private func restoreSavedValues() {
        guard !saving else { return }
        draft = store.settings
        writers.forEach { $0(draft) }
        hasUnsavedChanges = false
        feedback.stringValue = ""
        feedback.toolTip = nil
        updateDependentControls()
        updateButtons()
    }

    private func show(_ page: Page) {
        window?.makeFirstResponder(nil)
        scrollPositions[currentPage] = scrollView.contentView.bounds.origin
        currentPage = page
        heading.stringValue = page.title
        subtitle.stringValue = page.subtitle
        pageButtons.forEach { $0.value.active = $0.key == page }
        scrollView.documentView = pages[page]
        scrollView.contentView.scroll(to: scrollPositions[page] ?? .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func changed() {
        hasUnsavedChanges = true
        feedback.textColor = Titanium.muted
        feedback.stringValue = "有未保存的修改"
        feedback.toolTip = nil
        updateButtons()
        updateDependentControls()
    }

    private func updateButtons() {
        saveButton.isEnabled = !saving && hasUnsavedChanges
        resetButton.isEnabled = !saving && hasUnsavedChanges
        applyTrackersButton?.isEnabled = !saving && !hasUnsavedChanges && !store.settings.defaultTrackers.isEmpty
    }

    private func updateDependentControls() {
        editableControls.forEach { $0.isEnabled = !saving; $0.alphaValue = saving ? 0.4 : 1 }
        trackerEditor?.isEditable = !saving
        trackerEditor?.alphaValue = saving ? 0.4 : 1
        queueControls.forEach { $0.isEnabled = draft.queueEnabled && !saving; $0.alphaValue = $0.isEnabled ? 1 : 0.4 }
        proxyControls.forEach { $0.isEnabled = draft.proxyType != 0 && !saving; $0.alphaValue = $0.isEnabled ? 1 : 0.4 }
    }

    private func buildPages() {
        for page in Page.allCases {
            let document = SurfaceView(frame: NSRect(x: 0, y: 0, width: documentWidth, height: viewportHeight))
            pages[page] = document
            var y: CGFloat = 0
            switch page {
            case .general:
                group("窗口", in: document, y: &y) { box, row in
                    toggle("关闭窗口后继续传输", detail: "关闭按钮只隐藏窗口；退出应用会停止传输。", key: \.closeKeepsTransfers, in: box, y: &row)
                }
                group("提醒", in: document, y: &y) { box, row in
                    toggle("下载完成通知", detail: "首次启用时请求系统通知权限。", key: \.notifyOnCompletion, in: box, y: &row)
                }
            case .downloads:
                group("文件保存", in: document, y: &y) { box, row in
                    pathRow(in: box, y: &row)
                    toggle("预分配文件空间", detail: "新任务提前分配磁盘空间。", key: \.preallocateFiles, in: box, y: &row)
                }
                group("添加任务", in: document, y: &y) { box, row in
                    toggle("添加后保持停止", detail: "手动开始后才连接节点并下载。", key: \.addPaused, in: box, y: &row)
                    toggle("顺序下载", detail: "优先按文件顺序下载；也应用于已有任务。", key: \.sequentialDownloads, in: box, y: &row)
                }
            case .connection:
                group("监听与端口映射", in: document, y: &y) { box, row in
                    integer("监听端口", detail: "0 为自动选择，范围 0–65535。", key: \.listenPort, in: box, y: &row)
                    toggle("UPnP 端口映射", detail: "允许支持 UPnP 的路由器映射监听端口。", key: \.enableUPnP, in: box, y: &row)
                    toggle("NAT-PMP 端口映射", detail: "允许支持 NAT-PMP 的路由器映射端口。", key: \.enableNATPMP, in: box, y: &row)
                }
                group("连接数量", in: document, y: &y) { box, row in
                    integer("全局最大连接数", detail: "0 表示不限。", key: \.maxConnections, unit: "个连接", in: box, y: &row)
                    integer("每个任务最大连接数", detail: "0 表示不限。", key: \.maxConnectionsPerTorrent, unit: "个连接", in: box, y: &row)
                }
            case .speed:
                group("全局速度限制", in: document, y: &y) { box, row in
                    integer("下载上限", detail: "0 表示不限速。", key: \.downloadLimitKB, unit: "KiB/s", in: box, y: &row)
                    integer("上传上限", detail: "0 表示不限速。", key: \.uploadLimitKB, unit: "KiB/s", in: box, y: &row)
                }
                group("上传并发", in: document, y: &y) { box, row in
                    integer("全局上传槽位", detail: "同时向多少个节点上传；0 表示不限。", key: \.uploadSlots, unit: "个槽位", in: box, y: &row)
                }
            case .bittorrent:
                group("节点发现与加密", in: document, y: &y) { box, row in
                    toggle("DHT 网络", detail: "通过分布式网络寻找节点。", key: \.enableDHT, in: box, y: &row)
                    toggle("节点交换 PeX", detail: "向已连接的节点获取更多节点。", key: \.enablePeX, in: box, y: &row)
                    toggle("本地节点发现 LSD", detail: "发现同一局域网中的节点。", key: \.enableLSD, in: box, y: &row)
                    choice("连接加密", options: ["优先使用加密", "仅允许加密", "禁用加密"], key: \.encryptionMode, in: box, y: &row)
                }
                group("任务队列", in: document, y: &y) { box, row in
                    toggle("启用队列管理", detail: "根据以下上限调度活动任务。", key: \.queueEnabled, in: box, y: &row)
                    queueControls.append(integer("最大活动下载数", key: \.maxActiveDownloads, unit: "个任务", in: box, y: &row))
                    queueControls.append(integer("最大活动上传数", key: \.maxActiveUploads, unit: "个任务", in: box, y: &row))
                    queueControls.append(integer("最大活动任务总数", key: \.maxActiveTorrents, unit: "个任务", in: box, y: &row))
                }
                group("做种停止条件", in: document, y: &y) { box, row in
                    decimal("分享率达到", detail: "0 为不限；达到任一启用的条件即停止做种。", key: \.seedRatioLimit, in: box, y: &row)
                    integer("做种时间达到", detail: "0 为不限，累计做种时长达到上限后停止。", key: \.seedTimeLimitMinutes, unit: "分钟", in: box, y: &row)
                }
            case .trackers:
                group("自动追加", in: document, y: &y) { box, row in
                    toggle("新任务加入默认 Tracker", detail: "添加新任务时追加以下列表，保留任务自带的 Tracker。", key: \.autoAddTrackers, in: box, y: &row)
                }
                group("默认 Tracker", in: document, y: &y) { box, row in
                    trackerList(in: box, y: &row)
                }
            case .advanced:
                group("传输协议", in: document, y: &y) { box, row in
                    choice("允许的连接协议", options: ["TCP 与 µTP", "仅 TCP", "仅 µTP"], key: \.transportMode, in: box, y: &row)
                }
                group("代理服务器", in: document, y: &y) { box, row in
                    choice("代理类型", detail: "目前支持无需用户名和密码的代理。", options: ["不使用代理", "SOCKS5", "HTTP"], key: \.proxyType, in: box, y: &row)
                    proxyControls.append(string("服务器地址", placeholder: "127.0.0.1 或 proxy.example.com", key: \.proxyHost, in: box, y: &row))
                    proxyControls.append(integer("代理端口", detail: "范围 1–65535。", key: \.proxyPort, in: box, y: &row))
                    proxyControls.append(toggle("通过代理连接节点", key: \.proxyPeers, in: box, y: &row))
                    proxyControls.append(toggle("通过代理连接 Tracker", key: \.proxyTrackers, in: box, y: &row))
                }
            }
            document.setFrameSize(NSSize(width: documentWidth, height: max(viewportHeight, y)))
        }
    }

    private func group(_ title: String, in document: NSView, y: inout CGFloat,
                       content: (SurfaceView, inout CGFloat) -> Void) {
        let caption = Titanium.label(title, size: 11, color: Titanium.muted)
        caption.frame = NSRect(x: 2, y: y, width: documentWidth - 4, height: 21)
        document.addSubview(caption)
        y += 26
        let box = SurfaceView(frame: NSRect(x: 0, y: y, width: documentWidth, height: 0), color: Titanium.background, radius: 10)
        document.addSubview(box)
        var row: CGFloat = 4
        content(box, &row)
        box.setFrameSize(NSSize(width: documentWidth, height: row + 4))
        y += row + 18
    }

    private func caption(_ title: String, detail: String?, in view: NSView, y: CGFloat) {
        let label = Titanium.label(title, size: 12)
        label.frame = NSRect(x: 18, y: y + 13, width: inputColumnX - 36, height: 22)
        view.addSubview(label)
        if let detail {
            let hint = Titanium.label(detail, size: 10, color: Titanium.muted)
            hint.frame = NSRect(x: 18, y: y + 42, width: documentWidth - 36, height: 19)
            hint.toolTip = detail
            view.addSubview(hint)
        }
    }

    private func underlineContainer(in view: NSView, y: CGFloat) -> SurfaceView {
        let container = SurfaceView(frame: NSRect(x: inputColumnX, y: y + 9, width: inputWidth, height: 30))
        let line = SurfaceView(frame: NSRect(x: 0, y: 29, width: inputWidth, height: 1), color: NSColor(hex: 0xCBD2DD))
        container.addSubview(line)
        view.addSubview(container)
        return container
    }

    private func makeInput(title: String, in view: NSView, y: CGFloat) -> NSTextField {
        let container = underlineContainer(in: view, y: y)
        // Keep AppKit's normal cell/editor geometry. Padding belongs to the
        // container, so entering edit mode cannot apply a different text inset.
        let field = NSTextField(frame: NSRect(x: 0, y: 4, width: inputWidth, height: 22))
        field.isEditable = true
        field.isSelectable = true
        field.font = Titanium.font(12)
        field.textColor = Titanium.text
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = self
        field.cell?.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.setAccessibilityLabel(title)
        container.addSubview(field)
        editableControls.append(field)
        return field
    }

    @discardableResult
    private func integer(_ title: String, detail: String? = nil, key: WritableKeyPath<AppSettings, Int>,
                         unit: String? = nil, in view: NSView, y: inout CGFloat) -> NSTextField {
        caption(title, detail: detail, in: view, y: y)
        let field = makeInput(title: title, in: view, y: y)
        field.alignment = .right
        if let unit {
            let label = Titanium.label(unit, size: 11, color: Titanium.muted)
            label.frame = NSRect(x: inputColumnX + inputWidth + 14, y: y + 14, width: documentWidth - inputColumnX - inputWidth - 32, height: 22)
            view.addSubview(label)
        }
        writers.append { [weak field] value in field?.stringValue = String(value[keyPath: key]) }
        readers.append { [weak self, weak field] in
            guard let self, let field, field.isEnabled else { return }
            guard let value = Int(field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw ClientError.message("“\(title)”请输入整数。")
            }
            self.draft[keyPath: key] = value
        }
        y += detail == nil ? 52 : 72
        return field
    }

    private func decimal(_ title: String, detail: String?, key: WritableKeyPath<AppSettings, Double>,
                         in view: NSView, y: inout CGFloat) {
        caption(title, detail: detail, in: view, y: y)
        let field = makeInput(title: title, in: view, y: y)
        field.alignment = .right
        writers.append { [weak field] value in field?.stringValue = String(value[keyPath: key]) }
        readers.append { [weak self, weak field] in
            guard let self, let field else { return }
            guard let value = Double(field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)), value.isFinite else {
                throw ClientError.message("“\(title)”请输入有效数字。")
            }
            self.draft[keyPath: key] = value
        }
        y += 72
    }

    @discardableResult
    private func string(_ title: String, placeholder: String, key: WritableKeyPath<AppSettings, String>,
                        in view: NSView, y: inout CGFloat) -> NSTextField {
        caption(title, detail: nil, in: view, y: y)
        let field = makeInput(title: title, in: view, y: y)
        field.placeholderString = placeholder
        writers.append { [weak field] value in field?.stringValue = value[keyPath: key] }
        readers.append { [weak self, weak field] in
            guard let field else { return }
            self?.draft[keyPath: key] = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        y += 52
        return field
    }

    @discardableResult
    private func toggle(_ title: String, detail: String? = nil, key: WritableKeyPath<AppSettings, Bool>,
                        in view: NSView, y: inout CGFloat) -> NSSwitch {
        caption(title, detail: detail, in: view, y: y)
        let toggle = NSSwitch(frame: NSRect(x: inputColumnX, y: y + 10, width: 42, height: 28))
        toggle.controlSize = .regular
        toggle.setAccessibilityLabel(title)
        toggle.target = self
        toggle.action = #selector(controlChanged(_:))
        actions[ObjectIdentifier(toggle)] = { [weak self, weak toggle] in
            self?.draft[keyPath: key] = toggle?.state == .on
            self?.changed()
        }
        writers.append { [weak toggle] value in toggle?.state = value[keyPath: key] ? .on : .off }
        view.addSubview(toggle)
        editableControls.append(toggle)
        y += detail == nil ? 52 : 72
        return toggle
    }

    private func choice(_ title: String, detail: String? = nil, options: [String], key: WritableKeyPath<AppSettings, Int>,
                        in view: NSView, y: inout CGFloat) {
        caption(title, detail: detail, in: view, y: y)
        let container = underlineContainer(in: view, y: y)
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: inputWidth, height: 28))
        popup.addItems(withTitles: options)
        popup.font = Titanium.font(12)
        popup.bezelStyle = .regularSquare
        popup.isBordered = false
        popup.focusRingType = .none
        popup.contentTintColor = Titanium.text
        popup.setAccessibilityLabel(title)
        popup.target = self
        popup.action = #selector(controlChanged(_:))
        actions[ObjectIdentifier(popup)] = { [weak self, weak popup] in
            guard let popup else { return }
            self?.draft[keyPath: key] = popup.indexOfSelectedItem
            self?.changed()
        }
        writers.append { [weak popup] value in popup?.selectItem(at: value[keyPath: key]) }
        container.addSubview(popup)
        editableControls.append(popup)
        y += detail == nil ? 52 : 72
    }

    private func trackerList(in view: NSView, y: inout CGFloat) {
        let hint = Titanium.label("每行一个地址，支持 HTTP、HTTPS 和 UDP；保存时自动去重。", size: 10, color: Titanium.muted)
        hint.frame = NSRect(x: 18, y: y + 6, width: documentWidth - 36, height: 19)
        view.addSubview(hint)

        let editorScroll = NSScrollView(frame: NSRect(x: 18, y: y + 32, width: documentWidth - 36, height: 118))
        editorScroll.hasVerticalScroller = true
        editorScroll.autohidesScrollers = true
        editorScroll.scrollerStyle = .overlay
        editorScroll.borderType = .noBorder
        editorScroll.drawsBackground = true
        editorScroll.backgroundColor = Titanium.panel
        editorScroll.wantsLayer = true
        editorScroll.layer?.cornerRadius = 7
        editorScroll.layer?.borderWidth = 1
        editorScroll.layer?.borderColor = NSColor(hex: 0xDCE1E8).cgColor
        editorScroll.layer?.masksToBounds = true

        let editor = NSTextView(frame: editorScroll.contentView.bounds)
        editor.isRichText = false
        editor.importsGraphics = false
        editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isContinuousSpellCheckingEnabled = false
        editor.font = Titanium.font(12)
        editor.textColor = Titanium.text
        editor.backgroundColor = Titanium.panel
        editor.insertionPointColor = Titanium.accent
        editor.textContainerInset = NSSize(width: 9, height: 7)
        editor.textContainer?.lineFragmentPadding = 0
        editor.isHorizontallyResizable = false
        editor.isVerticallyResizable = true
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.delegate = self
        editor.setAccessibilityLabel("默认 Tracker 地址列表")
        editorScroll.documentView = editor
        view.addSubview(editorScroll)
        trackerEditor = editor
        writers.append { [weak editor] value in
            editor?.string = value.defaultTrackers
            editor?.undoManager?.removeAllActions()
        }
        readers.append { [weak self, weak editor] in
            guard let editor else { return }
            self?.draft.defaultTrackers = editor.string
        }

        let apply = ActionButton("应用到现有任务", symbol: "plus", frame: NSRect(x: 18, y: y + 162, width: 166, height: 30)) { [weak self] in
            self?.applySavedTrackers()
        }
        apply.restingColor = Titanium.selection
        apply.tint = Titanium.accent
        apply.toolTip = "先保存设置，再将已保存列表追加到现有任务；不会删除原有 Tracker。"
        view.addSubview(apply)
        applyTrackersButton = apply
        let savedHint = Titanium.label("追加已保存列表，保留任务原有 Tracker。", size: 10, color: Titanium.muted)
        savedHint.frame = NSRect(x: 196, y: y + 167, width: documentWidth - 214, height: 20)
        view.addSubview(savedHint)
        y += 206
    }

    private func applySavedTrackers() {
        guard !saving && !hasUnsavedChanges && !store.settings.defaultTrackers.isEmpty else { return }
        window?.makeFirstResponder(nil)
        saving = true
        updateButtons()
        updateDependentControls()
        feedback.textColor = Titanium.muted
        feedback.toolTip = nil
        feedback.stringValue = "正在追加已保存的 Tracker…"
        store.applyDefaultTrackers { [weak self] changed in
            guard let self else { return }
            self.saving = false
            self.feedback.textColor = changed != nil ? Titanium.green : Titanium.red
            if let changed {
                self.feedback.stringValue = changed > 0 ? "已为 \(changed) 个任务追加 Tracker" : "没有需要追加 Tracker 的任务"
            } else {
                self.feedback.stringValue = "追加失败，请修正问题后重试。"
            }
            self.updateButtons()
            self.updateDependentControls()
        }
    }

    private func pathRow(in view: NSView, y: inout CGFloat) {
        caption("默认保存位置", detail: nil, in: view, y: y)
        let field = makeInput(title: "默认保存位置", in: view, y: y)
        field.isEditable = false
        field.isSelectable = true
        field.cell?.isScrollable = false
        field.cell?.lineBreakMode = .byTruncatingMiddle
        pathField = field
        writers.append { [weak field] value in field?.stringValue = value.downloadPath; field?.toolTip = value.downloadPath }
        let choose = ActionButton("选择目录…", symbol: "folder",
                                  frame: NSRect(x: inputColumnX + inputWidth + 20, y: y + 9, width: 158, height: 30)) { [weak self] in
            self?.chooseDirectory()
        }
        choose.restingColor = Titanium.selection
        choose.tint = Titanium.accent
        view.addSubview(choose)
        editableControls.append(choose)
        y += 52
    }

    @objc private func controlChanged(_ sender: NSControl) {
        actions[ObjectIdentifier(sender)]?()
    }

    func controlTextDidChange(_ notification: Notification) { changed() }
    func textDidChange(_ notification: Notification) { changed() }

    private func chooseDirectory() {
        window?.makeFirstResponder(nil)
        store.chooseDirectory(initial: URL(fileURLWithPath: draft.downloadPath)) { [weak self] url in
            guard let self else { return }
            self.draft.downloadPath = url.path
            self.pathField?.stringValue = url.path
            self.pathField?.toolTip = url.path
            self.changed()
        }
    }

    private func save() {
        guard !saving else { return }
        window?.makeFirstResponder(nil)
        let originalDraft = draft
        do {
            try readers.forEach { try $0() }
            let candidate = try draft.validated()
            saving = true
            updateButtons()
            updateDependentControls()
            feedback.textColor = Titanium.muted
            feedback.stringValue = "正在保存…"
            store.updateSettings(candidate) { [weak self] success in
                guard let self else { return }
                self.saving = false
                if success {
                    self.draft = self.store.settings
                    self.writers.forEach { $0(self.draft) }
                    self.hasUnsavedChanges = false
                }
                self.feedback.textColor = success ? Titanium.green : Titanium.red
                self.feedback.toolTip = nil
                self.feedback.stringValue = success ? "设置已保存" : "保存失败，请修正问题后重试。"
                self.updateButtons()
                self.updateDependentControls()
            }
        } catch {
            // Preserve raw field edits, but do not retain a partially parsed draft.
            draft = originalDraft
            feedback.textColor = Titanium.red
            feedback.stringValue = error.localizedDescription
            feedback.toolTip = error.localizedDescription
        }
    }
}
