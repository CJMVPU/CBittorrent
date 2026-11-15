import AppKit

/// Every surface uses the approved calligraphic artwork, never a replacement glyph.
enum BrandMark {
    // The source has transparent padding. This rect encloses the original ink
    // in AppKit's bottom-left coordinate system (1254 × 1254 source pixels).
    private static let inkRect = NSRect(x: 153, y: 242, width: 919, height: 752)

    static func artwork(at url: URL? = nil) -> NSImage? {
        guard let source = url ?? Bundle.main.url(forResource: "CB-symbol", withExtension: "png"),
              let image = NSImage(contentsOf: source) else { return nil }
        image.size = NSSize(width: 1254, height: 1254)
        return image
    }

    static func draw(_ artwork: NSImage, in rect: NSRect) {
        let scale = min(rect.width / inkRect.width, rect.height / inkRect.height)
        let size = NSSize(width: inkRect.width * scale, height: inkRect.height * scale)
        let target = NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
                            width: size.width, height: size.height)
        artwork.draw(in: target, from: inkRect, operation: .sourceOver, fraction: 1)
    }

    static func menuImage() -> NSImage? {
        guard let artwork = artwork() else { return nil }
        let image = NSImage(size: NSSize(width: 22, height: 20), flipped: false) { rect in
            draw(artwork, in: rect.insetBy(dx: 1, dy: 1))
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "CBittorrent"
        return image
    }
}
