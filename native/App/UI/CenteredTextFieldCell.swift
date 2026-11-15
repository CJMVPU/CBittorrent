import AppKit

/// Keep the displayed line and AppKit's shared field editor on the same rect.
/// Centering only drawingRect leaves the insertion point at the old origin.
final class CenteredTextFieldCell: NSTextFieldCell {
    private let textLayout = NSLayoutManager()

    override func drawingRect(forBounds bounds: NSRect) -> NSRect {
        var rect = super.drawingRect(forBounds: bounds)
        let lineHeight = textLayout.defaultLineHeight(for: font ?? NSFont.systemFont(ofSize: 12))
        let height = min(lineHeight, rect.height)
        rect.origin.y = rect.midY - height / 2
        rect.size.height = height
        return rect
    }

    override func select(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText,
                         delegate: Any?, start selStart: Int, length selLength: Int) {
        super.select(withFrame: drawingRect(forBounds: rect), in: controlView,
                     editor: textObj, delegate: delegate, start: selStart, length: selLength)
    }

    override func edit(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText,
                       delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: drawingRect(forBounds: rect), in: controlView,
                   editor: textObj, delegate: delegate, event: event)
    }
}
