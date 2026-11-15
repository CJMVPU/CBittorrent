import Foundation

/// Reserve the compact numeric columns and give the name the remaining width.
enum TransferTableLayout {
    static func columnWidths(availableWidth: CGFloat) -> [CGFloat] {
        let fixed: [CGFloat] = [90, 78, 90, 84, 84, 62, 96]
        return [max(0, availableWidth - fixed.reduce(0, +))] + fixed
    }
}
