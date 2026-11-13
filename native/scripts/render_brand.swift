import AppKit

/// Package the approved artwork on a rounded tile with true alpha corners.
@main
struct RenderBrand {
    static func main() throws {
        guard CommandLine.arguments.count == 3 else { fatalError("Usage: render_brand output.png artwork.png") }
        let size = 1024
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor.white.setFill()
        NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 184, yRadius: 184).fill()
        guard let artwork = BrandMark.artwork(at: URL(fileURLWithPath: CommandLine.arguments[2])) else {
            fatalError("Approved artwork is missing")
        }
        BrandMark.draw(artwork, in: NSRect(x: 212, y: 212, width: 600, height: 600))
        NSGraphicsContext.restoreGraphicsState()
        try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
    }
}
