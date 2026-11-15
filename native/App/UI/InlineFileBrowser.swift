import AppKit

/// A small filesystem picker embedded in the same page; no NSOpenPanel or sheet.
final class InlineFileBrowser: SurfaceView {
    enum Mode { case torrents, directory, browse }
    private let mode: Mode
    private let onSelect: ([URL]) -> Void
    private let path = NSTextField()
    private let folderName = NSTextField()
    private let message = Titanium.label(size: 10, color: Titanium.muted)
    private let list = FlowListView(frame: NSRect(x: 28, y: 181, width: 844, height: 242))
    private var directory: URL
    private var entries: [FileSystemService.Entry] = []
    private var requestToken = UUID()
    private var loading = false

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
        for case let button as ActionButton in subviews {
            button.fitWidthToContent(keepingTrailingEdge: button.frame.maxX == 872)
        }
        navigate(initial)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    private func navigate(_ url: URL) {
        let resolved = url.standardizedFileURL
        let token = UUID()
        requestToken = token
        loading = true
        message.stringValue = "正在读取文件夹…"
        FileSystemService.list(resolved) { [weak self] result in
            guard let self, self.requestToken == token else { return }
            self.loading = false
            switch result {
            case .success(let entries):
                let values = entries.filter { $0.isDirectory || self.mode == .browse || (self.mode == .torrents && $0.url.pathExtension.lowercased() == "torrent") }
                self.directory = resolved
                self.entries = values
                self.path.stringValue = resolved.path
                self.path.toolTip = resolved.path
                self.list.clearSelection()
                self.list.strings = values.map { ($0.isDirectory ? "▸  " : "    ") + $0.url.lastPathComponent }
                self.message.stringValue = values.isEmpty ? "文件夹为空；可前往上一级或输入其他路径。" : "双击文件夹进入；也可直接输入路径。"
                self.message.textColor = Titanium.muted
            case .failure(let error):
                self.path.stringValue = self.directory.path
                self.message.stringValue = error.localizedDescription
                self.message.toolTip = error.localizedDescription
                self.message.textColor = Titanium.red
            }
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
        guard !loading else { return }
        guard let index = list.selectedIndexes.first, entries.indices.contains(index) else { return }
        let entry = entries[index]
        if entry.isDirectory { navigate(entry.url) }
        else if mode == .browse { showFileInfo(entry.url) }
        else { onSelect([entry.url]) }
    }

    private func accept() {
        guard !loading else { return }
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
        let token = UUID()
        requestToken = token
        FileSystemService.fileSize(url) { [weak self] result in
            guard let self, self.requestToken == token else { return }
            switch result {
            case .success(let bytes):
                self.message.stringValue = "\(url.lastPathComponent) · \(Titanium.bytes(bytes))"
                self.message.toolTip = url.path
                self.message.textColor = Titanium.text
            case .failure(let error):
                self.message.stringValue = error.localizedDescription
                self.message.textColor = Titanium.red
            }
        }
    }

    private func createFolder() {
        guard !loading else { return }
        let name = folderName.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else {
            message.stringValue = "请输入不含斜杠的有效文件夹名称。"; message.textColor = Titanium.red; return
        }
        let created = directory.appendingPathComponent(name, isDirectory: true)
        let token = UUID()
        requestToken = token
        loading = true
        FileSystemService.createDirectory(created) { [weak self] result in
            guard let self, self.requestToken == token else { return }
            self.loading = false
            switch result {
            case .success:
                self.folderName.stringValue = ""
                self.navigate(created)
            case .failure(let error):
                self.message.stringValue = error.localizedDescription
                self.message.textColor = Titanium.red
            }
        }
    }
}
