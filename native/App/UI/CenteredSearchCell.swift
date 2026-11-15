import AppKit

/// Explicit text and icon geometry keeps the compact search aligned at 24pt.
final class CenteredSearchCell: NSSearchFieldCell {
    private let textLayout = NSLayoutManager()

    override func searchTextRect(forBounds rect: NSRect) -> NSRect {
        let lineHeight = textLayout.defaultLineHeight(for: font ?? NSFont.systemFont(ofSize: 12))
        let height = min(lineHeight, rect.height)
        return NSRect(x: rect.minX + 28, y: rect.midY - height / 2,
                      width: max(0, rect.width - 52), height: height)
    }
    override func searchButtonRect(forBounds rect: NSRect) -> NSRect {
        NSRect(x: rect.minX + 8, y: rect.midY - 7, width: 14, height: 14)
    }
    override func cancelButtonRect(forBounds rect: NSRect) -> NSRect {
        NSRect(x: rect.maxX - 22, y: rect.midY - 7, width: 14, height: 14)
    }
}
