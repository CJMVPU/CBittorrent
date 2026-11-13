import AppKit
import QuartzCore

enum Titanium {
    static let background = NSColor(hex: 0xF9FAFB)
    static let panel = NSColor.white
    static let chrome = NSColor(hex: 0xEEF0F3)
    static let text = NSColor(hex: 0x303744)
    static let muted = NSColor(hex: 0x7D8592)
    static let accent = NSColor(hex: 0x5D7DB4)
    static let selection = NSColor(hex: 0xEAF0F9)
    static let hover = NSColor(hex: 0xE8EBEF)
    static let green = NSColor(hex: 0x39846B)
    static let orange = NSColor(hex: 0xAD8144)
    static let red = NSColor(hex: 0xB45E69)

    // A single point increase keeps every view on the same typographic scale.
    // Header/footer geometry remains 32/27 points.
    static func font(_ baseSize: CGFloat) -> NSFont {
        let size = baseSize + 1
        return NSFont(name: "LXGWWenKaiMono-Medium", size: size)
            ?? NSFont(name: "LXGW WenKai Mono Medium", size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .medium)
    }

    static func label(_ text: String = "", size: CGFloat = 12, color: NSColor = Titanium.text,
                      alignment: NSTextAlignment = .left) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = font(size)
        label.textColor = color
        label.alignment = alignment
        label.lineBreakMode = .byTruncatingTail
        return label
    }

    static func bytes(_ value: Int64) -> String {
        let units = ["B", "KiB", "MiB", "GiB", "TiB"]
        var amount = Double(max(0, value))
        var unit = 0
        while amount >= 1024 && unit < units.count - 1 {
            amount /= 1024
            unit += 1
        }
        return unit == 0 ? "\(Int(amount)) B" : String(format: amount >= 100 ? "%.0f %@" : "%.1f %@", amount, units[unit])
    }

    static func rate(_ value: Int64) -> String {
        value > 0 ? bytes(value) : "—"
    }

    static func duration(_ seconds: Int64) -> String {
        guard seconds >= 0 else { return "—" }
        if seconds >= 86400 { return "\(seconds / 86400)d \((seconds % 86400) / 3600)h" }
        if seconds >= 3600 { return "\(seconds / 3600)h \((seconds % 3600) / 60)m" }
        return "\(seconds / 60)m \(seconds % 60)s"
    }

    static func state(_ state: String) -> String {
        switch state {
        case "downloading": return "下载中"
        case "metadata": return "获取元数据"
        case "seeding": return "做种中"
        case "paused": return "已停止"
        case "queued": return "排队中"
        case "checking": return "校验中"
        case "error": return "错误"
        default: return state
        }
    }

    static func stateColor(_ state: String) -> NSColor {
        switch state {
        case "downloading", "metadata": return accent
        case "seeding": return green
        case "queued", "checking": return orange
        case "error": return red
        default: return muted
        }
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 255) / 255,
                  green: CGFloat((hex >> 8) & 255) / 255,
                  blue: CGFloat(hex & 255) / 255, alpha: 1)
    }
}

class SurfaceView: NSView {
    override var isFlipped: Bool { true }

    init(frame: NSRect = .zero, color: NSColor = .clear, radius: CGFloat = 0) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = color.cgColor
        layer?.cornerRadius = radius
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
}

final class TitlebarView: SurfaceView {
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

/// Draw the icon and title as one compact group. AppKit's image-leading layout
/// otherwise reserves separate regions for the icon and title in wide buttons.
final class ActionButtonCell: NSButtonCell {
    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        let hasImage = image != nil && imagePosition != .noImage
        let hasTitle = !title.isEmpty && imagePosition != .imageOnly
        let content = cellFrame.insetBy(dx: hasTitle ? 8 : 4, dy: 2)
        let iconSide = hasImage ? min((font?.pointSize ?? 12) + 1, content.height, content.width) : 0
        let gap: CGFloat = hasImage && hasTitle ? 6 : 0
        let titleSize = hasTitle ? attributedTitle.size() : .zero
        let titleWidth = min(ceil(titleSize.width), max(0, content.width - iconSide - gap))
        let groupWidth = iconSide + gap + titleWidth
        let originX: CGFloat
        switch alignment {
        case .left: originX = content.minX
        case .right: originX = content.maxX - groupWidth
        default: originX = cellFrame.midX - groupWidth / 2
        }
        if let image, hasImage {
            let imageFrame = NSRect(x: originX, y: cellFrame.midY - iconSide / 2,
                                    width: iconSide, height: iconSide)
            drawImage(image, withFrame: imageFrame, in: controlView)
        }
        if hasTitle {
            let titleFrame = NSRect(x: originX + iconSide + gap,
                                    y: cellFrame.midY - ceil(titleSize.height) / 2,
                                    width: titleWidth, height: ceil(titleSize.height))
            let text = NSMutableAttributedString(attributedString: attributedTitle)
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .left
            paragraph.lineBreakMode = .byTruncatingTail
            text.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: text.length))
            text.draw(in: titleFrame)
        }
    }
}

final class ActionButton: NSButton {
    var handler: (() -> Void)?
    var active = false { didSet { updateAppearance() } }
    var selectionChangesBackground = true { didSet { updateAppearance() } }
    var restingColor: NSColor = .clear { didSet { updateAppearance() } }
    var tint: NSColor = Titanium.muted { didSet { updateAppearance() } }
    var hoverColor: NSColor = Titanium.hover
    private var hovering = false
    private var hoverTracking: NSTrackingArea?

    init(_ title: String = "", symbol: String? = nil, frame: NSRect = .zero, action: (() -> Void)? = nil) {
        super.init(frame: frame)
        cell = ActionButtonCell(textCell: title)
        setButtonType(.momentaryPushIn)
        alignment = .center
        self.title = title
        handler = action
        isBordered = false
        bezelStyle = .regularSquare
        focusRingType = .exterior
        font = Titanium.font(11)
        wantsLayer = true
        layer?.cornerRadius = 6
        target = self
        self.action = #selector(performAction)
        if let symbol {
            image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .regular))
            imagePosition = title.isEmpty ? .imageOnly : .imageLeading
        }
        setAccessibilityLabel(title)
        updateAppearance()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override var isEnabled: Bool {
        didSet { alphaValue = isEnabled ? 1 : 0.35 }
    }

    override func updateTrackingAreas() {
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(rect: bounds, options: [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverTracking = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; updateAppearance() }
    override func mouseExited(with event: NSEvent) { hovering = false; updateAppearance() }

    private func updateAppearance() {
        layer?.backgroundColor = (active && selectionChangesBackground ? Titanium.selection : hovering ? hoverColor : restingColor).cgColor
        contentTintColor = active ? Titanium.accent : tint
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: font ?? Titanium.font(11),
            .foregroundColor: active ? Titanium.accent : tint
        ])
    }

    func setTitle(_ text: String) { title = text; updateAppearance() }
    @objc private func performAction() { handler?() }
}

final class ProgressTrack: SurfaceView {
    var progress: Double = 0 { didSet { needsDisplay = true } }
    var tint = Titanium.accent { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        Titanium.chrome.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 2, yRadius: 2).fill()
        tint.setFill()
        let filled = NSRect(x: 0, y: 0, width: bounds.width * min(1, max(0, progress)), height: bounds.height)
        NSBezierPath(roundedRect: filled, xRadius: 2, yRadius: 2).fill()
    }
}
