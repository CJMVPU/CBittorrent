import AppKit
import QuartzCore

@main
struct UITest {
    @MainActor
    static func main() async throws {
        _ = NSApplication.shared
        let widths = TransferTableLayout.columnWidths(availableWidth: 888)
        precondition(widths.count == 8 && widths.allSatisfy { $0 > 0 })
        precondition(widths.reduce(0, +) == 888, "Every column must fit the fixed viewport")
        precondition(widths[0] >= 200, "Keep the name usable in the compact window")
        precondition(StatusBarPresentation.widths.reduce(13, +) <= 900)
        var traffic = EngineSnapshot()
        precondition(StatusBarPresentation.ratio(traffic) == "—")
        traffic.historicalDownloaded = 0
        traffic.historicalUploaded = 0
        precondition(StatusBarPresentation.ratio(traffic) == "—")
        traffic.historicalUploaded = 1
        precondition(StatusBarPresentation.ratio(traffic) == "∞")
        traffic.historicalDownloaded = 4
        precondition(StatusBarPresentation.ratio(traffic) == "0.25")
        traffic.totalDownloaded = 999
        precondition(StatusBarPresentation.ratio(traffic) == "0.25", "Ratio must use history, not session totals")
        testMarquee()
        try testConnectionPageAndSettings()
        try await testMetadataReview()

        let list = FlowListView(frame: NSRect(x: 0, y: 0, width: 844, height: 278))
        list.strings = ["0% A", "0% B"]
        list.select(1)
        var callbacks = 0
        list.onSelection = { callbacks += 1 }
        list.strings = ["10% A", "50% B"]
        precondition(list.selectedIndexes == IndexSet(integer: 1), "Progress refresh must retain selection")
        precondition(callbacks == 0, "Progress refresh must not overwrite an edited priority choice")
        list.strings = []
        precondition(list.selectedIndexes.isEmpty)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data([1, 2, 3]).write(to: directory.appendingPathComponent("example.torrent"))
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("Folder"), withIntermediateDirectories: false)
        let result: Result<[FileSystemService.Entry], Error> = await withCheckedContinuation { continuation in
            FileSystemService.list(directory) { continuation.resume(returning: $0) }
        }
        let entries = try result.get()
        precondition(entries.count == 2 && entries[0].isDirectory)
        precondition(entries[1].url.lastPathComponent == "example.torrent")
        let failure: Result<[FileSystemService.Entry], Error> = await withCheckedContinuation { continuation in
            FileSystemService.list(directory.appendingPathComponent("missing")) { continuation.resume(returning: $0) }
        }
        if case .success = failure { preconditionFailure("Missing folder must report failure") }
        print("PASS: UI geometry, marquee rendering/lifecycle, stable detail selection, asynchronous filesystem success/failure")
    }

    @MainActor
    private static func testConnectionPageAndSettings() throws {
        let effects = UIPreviewEffects()
        let settings = AppSettings()
        let store = AppStore(application: TransferApplication(engine: UIPreviewEngine(), repository: effects,
            directory: effects, notifier: effects, settings: settings))
        let fixture = Data(#"{"id":"one","name":"A","state":"downloading","progress":0.5,"totalSize":10,"downloaded":5,"uploaded":0,"downloadRate":1,"uploadRate":0,"eta":5,"ratio":0,"peers":2,"seeds":1,"savePath":"/tmp","error":"","files":[],"trackers":[]}"#.utf8)
        var torrent = try JSONDecoder().decode(TorrentSnapshot.self, from: fixture)
        let peer = PeerSnapshot(address: "2001:db8::1", port: 6881, localAddress: "::1", localPort: 1234,
            client: "Test peer", progress: 0.5, downloadRate: 512, uploadRate: 64, downloaded: 1024, uploaded: 128,
            transport: "TCP", outgoing: true, encryption: "Handshake", state: "connected", uploadChoked: false,
            downloadChoked: true, sources: ["DHT"])
        precondition(peer.endpoint == "[2001:db8::1]:6881", "IPv6 endpoint must be unambiguous")
        torrent.connections = [peer]
        let view = PeerDetailView(torrent: torrent, store: store)
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
        let nodes = descendants(view)
        let table = nodes.compactMap { $0 as? NSTableView }.first!
        precondition(table.numberOfRows == 1 && table.tableColumns.count == 7)
        precondition(table.headerView!.frame.height > 0)
        let pause = nodes.compactMap { $0 as? ActionButton }.first { $0.title == "暂停刷新" }!
        pause.performClick(nil)
        precondition(pause.title == "继续刷新")
        precondition(pause.accessibilityLabel() == "继续刷新")
        precondition(table.tableColumns.reduce(0) { $0 + $1.width } <= 844)
        table.selectRowIndexes([0], byExtendingSelection: false)
        let text = nodes.compactMap { $0 as? NSTextField }.map(\.stringValue).joined(separator: " ")
        precondition(text.contains("仅握手混淆") && text.contains("DHT") && text.contains("[::1]:1234"))
        let search = nodes.compactMap { $0 as? NSSearchField }.first!
        search.stringValue = "no-match"
        search.sendAction(search.action, to: search.target)
        precondition(table.numberOfRows == 0 && table.selectedRow == -1)
        search.stringValue = "Test peer"
        search.sendAction(search.action, to: search.target)
        precondition(table.numberOfRows == 1)
        let preferences = SettingsView(store: store, onBack: {})
        preferences.frame = NSRect(x: 0, y: 0, width: 900, height: 541)
        for page in ["通用", "下载", "连接", "速度", "BitTorrent", "Tracker", "高级"] {
            let button = descendants(preferences).compactMap { $0 as? ActionButton }.first { $0.title == page }!
            button.performClick(nil)
            for field in descendants(preferences).compactMap({ $0 as? NSTextField }) {
                if let parent = field.superview {
                    precondition(field.frame.minX >= 0 && field.frame.maxX <= parent.bounds.width + 1,
                        "Settings field escapes its layout container")
                }
            }
        }
    }

    @MainActor
    private static func testMetadataReview() async throws {
        let engine = UIPreviewEngine()
        let fixture = Data(#"{"id":"preview","name":"Metadata fixture","state":"metadata","progress":0,"totalSize":1024,"downloaded":0,"uploaded":0,"downloadRate":0,"uploadRate":0,"eta":0,"ratio":0,"peers":0,"seeds":0,"savePath":"/tmp","error":"","files":[],"trackers":[],"metadataReady":true}"#.utf8)
        engine.metadata = try JSONDecoder().decode(TorrentSnapshot.self, from: fixture)
        let effects = UIPreviewEffects()
        let store = AppStore(application: TransferApplication(engine: engine, repository: effects,
            directory: effects, notifier: effects, settings: AppSettings()))
        var finished = false
        let view = MetadataReviewView(sources: ["fixture"], store: store) { finished = true }
        let button = view.subviews.compactMap { $0 as? ActionButton }.first { $0.title == "确认添加" }!
        precondition(!button.isEnabled && engine.confirmations == 0)
        for _ in 0..<100 where !button.isEnabled { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(button.isEnabled && engine.confirmations == 0, "Metadata must require explicit confirmation")
        button.performClick(nil)
        for _ in 0..<100 where !finished { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(finished && engine.confirmations == 1)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 541))
        let page = InWindowFlowView(request: .review(["cancelled"]), store: store, onClose: {})
        container.addSubview(page)
        await Task.yield()
        page.removeFromSuperview()
        try await Task.sleep(nanoseconds: 200_000_000)
        precondition(engine.confirmations == 1 && engine.activePreviews.isEmpty, "Leaving preview must clean up late async results")
    }

    @MainActor
    private static func testMarquee() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 304, height: 24),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let name = MarqueeNameView()
        window.contentView = name
        let longName = String(repeating: "Long filename ", count: 8) + "END.mkv"
        name.update(longName)
        name.layoutSubtreeIfNeeded()
        let viewport = name.subviews[1]
        guard let textLayer = viewport.layer?.sublayers?.compactMap({ $0 as? CATextLayer }).first else {
            preconditionFailure("The marquee must render the entire name independently of AppKit view clipping")
        }
        precondition(name.toolTip == longName)
        precondition(viewport.layer?.masksToBounds == true)
        let overflow = textLayer.bounds.width - viewport.bounds.width
        precondition(overflow > 0)

        // The suffix starts outside the initial viewport. It must already have
        // pixels before animation reveals it, rather than scrolling into blank backing.
        let width = Int(ceil(textLayer.bounds.width))
        let height = Int(ceil(textLayer.bounds.height))
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        textLayer.displayIfNeeded()
        textLayer.render(in: context)
        let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
        let suffixHasInk = (0..<height).contains { y in
            ((width - 45)..<width).contains { x in pixels[(y * width + x) * 4 + 3] > 0 }
        }
        precondition(suffixHasInk, "The end of a long filename must be drawn outside the initial viewport")

        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let animation = textLayer.animation(forKey: "name-scroll")!.copy() as! CAKeyframeAnimation
            let offsets = (animation.values as! [NSNumber]).map(\.doubleValue)
            precondition(offsets.min() == -Double(overflow) && offsets.max() == 0,
                         "Scroll only between the fully aligned start and end")
            precondition(animation.autoreverses && animation.repeatCount == .infinity)
            animation.beginTime = CACurrentMediaTime() - 2
            textLayer.add(animation, forKey: "name-scroll")
            name.update(longName)
            name.needsLayout = true
            name.layoutSubtreeIfNeeded()
            precondition(textLayer.animation(forKey: "name-scroll")?.beginTime == animation.beginTime,
                         "Unchanged snapshots must preserve the scroll phase")
            name.isHidden = true
            precondition(textLayer.animation(forKey: "name-scroll") == nil)
            name.isHidden = false
            name.layoutSubtreeIfNeeded()
            precondition(textLayer.animation(forKey: "name-scroll") != nil)
        }

        name.update("2026")
        name.layoutSubtreeIfNeeded()
        precondition(textLayer.animation(forKey: "name-scroll") == nil,
                     "Reusing a long-name cell for a short name must stop scrolling")
        precondition(textLayer.frame.minX == 0 && textLayer.frame.width == viewport.bounds.width)
        precondition(name.toolTip == "2026")
    }
}

private final class UIPreviewEngine: TransferEngine {
    var metadata: TorrentSnapshot?
    var confirmations = 0
    var activePreviews = Set<String>()
    func prepareMetadata(source: String) async throws -> String {
        try await Task.sleep(nanoseconds: 30_000_000)
        activePreviews.insert(source)
        return source
    }
    func cancelMetadata(id: String) async throws { activePreviews.remove(id) }
    func confirmMetadata(id: String, savePath: String, paused: Bool) async throws {
        confirmations += 1; activePreviews.remove(id)
    }
    func snapshot() async throws -> EngineSnapshot { EngineSnapshot() }
    func detail(id: String) async throws -> TorrentSnapshot { guard let metadata else { throw ClientError.message("Missing fixture") }; return metadata }
    func add(source: String, savePath: String, paused: Bool) async throws {}
    func pause(id: String) async throws {}
    func resume(id: String) async throws {}
    func remove(id: String, deleteFiles: Bool) async throws {}
    func setFilePriority(id: String, index: Int, priority: Int) async throws {}
    func applySettings(_ settings: AppSettings) async throws {}
    func applyDefaultTrackers() async throws -> Int { 0 }
    func save(all: Bool) async throws {}
    func close() async throws {}
}

@MainActor
private final class UIPreviewEffects: SettingsRepository, DownloadDirectory, CompletionNotifier {
    func load() throws -> AppSettings { AppSettings() }
    func save(_ settings: AppSettings) async throws {}
    func prepare(path: String) async throws {}
    func requestAuthorization() async {}
    func completed(_ torrent: TorrentSnapshot) async {}
}
