import AppKit
import QuartzCore

final class QuietHeaderCell: NSTableHeaderCell {
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Titanium.font(11), .foregroundColor: Titanium.muted, .paragraphStyle: paragraph
        ]
        let rect = NSRect(x: cellFrame.minX + 9, y: cellFrame.midY - 7,
                          width: cellFrame.width - 18, height: 17)
        (stringValue as NSString).draw(in: rect, withAttributes: attributes)
    }

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        draw(withFrame: cellFrame, in: controlView)
    }
}

final class QuietHeaderView: NSTableHeaderView {
    override func draw(_ dirtyRect: NSRect) {
        Titanium.panel.setFill()
        dirtyRect.fill()
        guard let tableView else { return }
        for (index, column) in tableView.tableColumns.enumerated() {
            column.headerCell.draw(withFrame: headerRect(ofColumn: index), in: self)
        }
    }
}

/// Extend the same row bands through unused space, including an empty table.
final class StripedTransferTableView: NSTableView {
    override func drawBackground(inClipRect clipRect: NSRect) {
        Titanium.panel.setFill()
        clipRect.fill()
        let pitch = rowHeight + intercellSpacing.height
        guard pitch > 0 else { return }
        let first = max(0, Int(floor(clipRect.minY / pitch)))
        let last = Int(ceil(clipRect.maxY / pitch))
        guard first <= last else { return }
        Titanium.stripe.setFill()
        for row in first...last where row % 2 == 1 {
            NSRect(x: clipRect.minX, y: CGFloat(row) * pitch,
                   width: clipRect.width, height: pitch).intersection(clipRect).fill()
        }
    }
}

final class TransferRowView: NSTableRowView {
    var alternate = false { didSet { needsDisplay = true } }

    override func drawBackground(in dirtyRect: NSRect) {
        (alternate ? Titanium.stripe : Titanium.panel).setFill()
        dirtyRect.fill()
    }

    override func drawSelection(in dirtyRect: NSRect) {
        Titanium.selection.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
}

/// Only overflowing labels move. Repeated snapshots do not restart their animation.
final class MarqueeNameView: SurfaceView {
    private let icon = NSImageView()
    private let viewport = SurfaceView()
    // Own the animated layer: AppKit may only draw the visible portion of a
    // layer-backed NSTextField, leaving blank text when its layer moves.
    private let nameLayer = CATextLayer()
    private var text = ""
    private var lastOverflow: CGFloat = -1

    override init(frame: NSRect = .zero, color: NSColor = .clear, radius: CGFloat = 0) {
        super.init(frame: frame, color: color, radius: radius)
        icon.image = NSImage(systemSymbolName: "doc", accessibilityDescription: nil)
        icon.contentTintColor = Titanium.muted
        viewport.layer?.masksToBounds = true
        nameLayer.alignmentMode = .left
        nameLayer.isWrapped = false
        addSubview(icon)
        addSubview(viewport)
        viewport.layer?.addSublayer(nameLayer)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(motionPreferenceChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    deinit { NSWorkspace.shared.notificationCenter.removeObserver(self) }

    override func viewDidHide() {
        super.viewDidHide()
        nameLayer.removeAnimation(forKey: "name-scroll")
        lastOverflow = -1
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        needsLayout = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        lastOverflow = -1
        nameLayer.removeAnimation(forKey: "name-scroll")
        needsLayout = true
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }

    @objc private func motionPreferenceChanged() {
        lastOverflow = -1
        nameLayer.removeAnimation(forKey: "name-scroll")
        needsLayout = true
    }

    func update(_ value: String) {
        guard text != value else { return }
        text = value
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        nameLayer.string = NSAttributedString(string: value, attributes: [
            .font: Titanium.font(12), .foregroundColor: Titanium.text
        ])
        CATransaction.commit()
        nameLayer.removeAnimation(forKey: "name-scroll")
        toolTip = value
        setAccessibilityLabel(value)
        lastOverflow = -1
        needsLayout = true
    }

    override func layout() {
        super.layout()
        icon.frame = NSRect(x: 9, y: (bounds.height - 13) / 2, width: 13, height: 13)
        viewport.frame = NSRect(x: 29, y: 0, width: max(0, bounds.width - 38), height: bounds.height)
        let textWidth = ceil((text as NSString).size(withAttributes: [.font: Titanium.font(12)]).width) + 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        nameLayer.contentsScale = window?.backingScaleFactor ?? 2
        nameLayer.frame = NSRect(x: 0, y: (bounds.height - 18) / 2,
                                width: max(textWidth, viewport.bounds.width), height: 18)
        CATransaction.commit()
        let overflow = max(0, textWidth - viewport.bounds.width)
        guard abs(overflow - lastOverflow) > 0.5 else { return }
        lastOverflow = overflow
        nameLayer.removeAnimation(forKey: "name-scroll")
        guard overflow > 0, viewport.bounds.width > 0, window != nil,
              !isHiddenOrHasHiddenAncestor, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let animation = CAKeyframeAnimation(keyPath: "transform.translation.x")
        animation.values = [0.0, 0.0, -Double(overflow), -Double(overflow)]
        animation.keyTimes = [0, 0.15, 0.85, 1]
        animation.duration = max(5, Double(overflow) / 22 + 2)
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timingFunctions = [.init(name: .linear), .init(name: .easeInEaseOut), .init(name: .linear)]
        nameLayer.add(animation, forKey: "name-scroll")
    }
}

final class ProgressCell: SurfaceView {
    private let track = ProgressTrack()
    private let percent = Titanium.label(size: 10, color: Titanium.muted, alignment: .right)

    override init(frame: NSRect = .zero, color: NSColor = .clear, radius: CGFloat = 0) {
        super.init(frame: frame, color: color, radius: radius)
        addSubview(track)
        addSubview(percent)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func update(_ torrent: TorrentSnapshot) {
        track.progress = torrent.progress
        track.tint = torrent.state == "seeding" ? Titanium.green : Titanium.accent
        percent.stringValue = "\(Int(min(1, max(0, torrent.progress)) * 100))%"
        setAccessibilityLabel("进度 \(percent.stringValue)")
    }

    override func layout() {
        super.layout()
        track.frame = NSRect(x: 9, y: bounds.midY - 1.5, width: max(0, bounds.width - 56), height: 3)
        percent.frame = NSRect(x: bounds.width - 44, y: bounds.midY - 8, width: 35, height: 17)
    }
}

final class ValueCell: SurfaceView {
    let label = Titanium.label()

    override init(frame: NSRect = .zero, color: NSColor = .clear, radius: CGFloat = 0) {
        super.init(frame: frame, color: color, radius: radius)
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func layout() {
        super.layout()
        label.frame = NSRect(x: 9, y: bounds.midY - 9, width: max(0, bounds.width - 18), height: 19)
    }
}
