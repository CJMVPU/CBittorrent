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
        testMarquee()

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
