import AppKit

final class SettingsView: SurfaceView {
    private let store: AppStore
    private let pathField = NSTextField()
    private let downloadLimit = NSTextField()
    private let uploadLimit = NSTextField()
    private let keepRunning = NSButton(checkboxWithTitle: "关闭窗口后继续传输", target: nil, action: nil)
    private let notifications = NSButton(checkboxWithTitle: "下载完成后通知我", target: nil, action: nil)
    private let addPaused = NSButton(checkboxWithTitle: "添加任务后保持停止", target: nil, action: nil)
    private let feedback = Titanium.label(size: 11, color: Titanium.muted)
    private let saveButton = ActionButton("保存设置", symbol: "checkmark")

    init(store: AppStore, onBack: @escaping () -> Void) {
        self.store = store
        super.init(color: Titanium.panel)
        let sidebar = SurfaceView(frame: NSRect(x: 0, y: 0, width: 166, height: 621), color: Titanium.background)
        addSubview(sidebar)
        let back = ActionButton("返回传输", symbol: "arrow.left", frame: NSRect(x: 15, y: 20, width: 125, height: 30), action: onBack)
        sidebar.addSubview(back)
        let general = ActionButton("通用设置", symbol: "slider.horizontal.3", frame: NSRect(x: 15, y: 73, width: 136, height: 30))
        general.active = true
        sidebar.addSubview(general)
        let platform = Titanium.label("原生 macOS 客户端\nApple Silicon", size: 10, color: Titanium.muted)
        platform.maximumNumberOfLines = 2
        platform.frame = NSRect(x: 24, y: 551, width: 130, height: 40)
        sidebar.addSubview(platform)
        let heading = Titanium.label("通用设置", size: 22)
        heading.frame = NSRect(x: 208, y: 29, width: 300, height: 32)
        addSubview(heading)
        let hint = Titanium.label("设置与传输共用一个窗口", size: 11, color: Titanium.muted, alignment: .right)
        hint.frame = NSRect(x: 650, y: 39, width: 307, height: 18)
        addSubview(hint)

        section("下载", y: 87)
        let downloadGroup = SurfaceView(frame: NSRect(x: 208, y: 112, width: 749, height: 116), color: Titanium.background, radius: 8)
        addSubview(downloadGroup)
        let pathCaption = Titanium.label("默认保存位置", size: 12)
        pathCaption.frame = NSRect(x: 15, y: 13, width: 160, height: 20)
        downloadGroup.addSubview(pathCaption)
        configure(pathField, frame: NSRect(x: 15, y: 43, width: 630, height: 25))
        pathField.isEditable = false
        pathField.isSelectable = true
        downloadGroup.addSubview(pathField)
        let choose = ActionButton("选择…", symbol: "folder", frame: NSRect(x: 654, y: 42, width: 80, height: 27)) { [weak self] in self?.chooseDirectory() }
        choose.restingColor = Titanium.panel
        downloadGroup.addSubview(choose)
        addPaused.frame = NSRect(x: 15, y: 81, width: 400, height: 22)
        downloadGroup.addSubview(addPaused)

        section("速度限制", y: 251)
        let speedGroup = SurfaceView(frame: NSRect(x: 208, y: 276, width: 749, height: 84), color: Titanium.background, radius: 8)
        addSubview(speedGroup)
        for (index, title) in ["下载上限", "上传上限"].enumerated() {
            let left = CGFloat(15 + index * 370)
            let caption = Titanium.label(title, size: 12)
            caption.frame = NSRect(x: left, y: 17, width: 96, height: 20)
            speedGroup.addSubview(caption)
            let field = index == 0 ? downloadLimit : uploadLimit
            configure(field, frame: NSRect(x: left + 99, y: 14, width: 118, height: 25))
            field.alignment = .right
            speedGroup.addSubview(field)
            let units = Titanium.label("KiB/s", size: 11, color: Titanium.muted)
            units.frame = NSRect(x: left + 229, y: 18, width: 70, height: 18)
            speedGroup.addSubview(units)
        }
        let unlimited = Titanium.label("0 表示不限速；保存后立即应用到传输引擎。", size: 10, color: Titanium.muted)
        unlimited.frame = NSRect(x: 15, y: 54, width: 700, height: 18)
        speedGroup.addSubview(unlimited)

        section("窗口与通知", y: 384)
        let behaviorGroup = SurfaceView(frame: NSRect(x: 208, y: 409, width: 749, height: 85), color: Titanium.background, radius: 8)
        addSubview(behaviorGroup)
        keepRunning.frame = NSRect(x: 15, y: 13, width: 600, height: 24)
        notifications.frame = NSRect(x: 15, y: 48, width: 600, height: 24)
        behaviorGroup.addSubview(keepRunning)
        behaviorGroup.addSubview(notifications)
        for toggle in [keepRunning, notifications, addPaused] {
            toggle.font = Titanium.font(12)
            toggle.contentTintColor = Titanium.text
        }
        saveButton.frame = NSRect(x: 839, y: 525, width: 118, height: 31)
        saveButton.handler = { [weak self] in self?.save() }
        saveButton.active = true
        addSubview(saveButton)
        feedback.frame = NSRect(x: 208, y: 532, width: 613, height: 19)
        addSubview(feedback)
        reload()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func reload() {
        pathField.stringValue = store.settings.downloadPath
        downloadLimit.stringValue = String(store.settings.downloadLimitKB)
        uploadLimit.stringValue = String(store.settings.uploadLimitKB)
        keepRunning.state = store.settings.closeKeepsTransfers ? .on : .off
        notifications.state = store.settings.notifyOnCompletion ? .on : .off
        addPaused.state = store.settings.addPaused ? .on : .off
        feedback.stringValue = ""
    }

    private func configure(_ field: NSTextField, frame: NSRect) {
        field.frame = frame
        field.font = Titanium.font(12)
        field.textColor = Titanium.text
        field.backgroundColor = Titanium.panel
        field.isBordered = false
        field.drawsBackground = true
        field.focusRingType = .exterior
        field.cell?.lineBreakMode = .byTruncatingMiddle
    }

    private func section(_ text: String, y: CGFloat) {
        let label = Titanium.label(text, size: 11, color: Titanium.muted)
        label.frame = NSRect(x: 208, y: y, width: 500, height: 20)
        addSubview(label)
    }

    private func chooseDirectory() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "选择目录"
        panel.directoryURL = URL(fileURLWithPath: pathField.stringValue)
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.pathField.stringValue = url.path
        }
    }

    private func save() {
        guard let down = Int(downloadLimit.stringValue), let up = Int(uploadLimit.stringValue),
              down >= 0, up >= 0, down <= Int(Int32.max) / 1024, up <= Int(Int32.max) / 1024 else {
            feedback.textColor = Titanium.red
            feedback.stringValue = "请输入有效的非负整数速度上限。"
            return
        }
        var settings = store.settings
        settings.downloadPath = pathField.stringValue
        settings.downloadLimitKB = down
        settings.uploadLimitKB = up
        settings.closeKeepsTransfers = keepRunning.state == .on
        settings.notifyOnCompletion = notifications.state == .on
        settings.addPaused = addPaused.state == .on
        saveButton.isEnabled = false
        feedback.textColor = Titanium.muted
        feedback.stringValue = "正在保存…"
        store.updateSettings(settings) { [weak self] success in
            guard let self else { return }
            self.saveButton.isEnabled = true
            self.feedback.textColor = success ? Titanium.green : Titanium.red
            self.feedback.stringValue = success ? "已保存" : "保存失败，请检查错误提示后重试。"
        }
    }
}
