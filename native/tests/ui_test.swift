import AppKit

@main
struct UITest {
    @MainActor
    static func main() async throws {
        _ = NSApplication.shared
        let widths = TransferTableLayout.columnWidths(availableWidth: 888)
        precondition(widths.count == 8 && widths.allSatisfy { $0 > 0 })
        precondition(widths.reduce(0, +) == 888, "Every column must fit the fixed viewport")
        precondition(widths[0] >= 200, "Keep the name usable in the compact window")

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
        print("PASS: UI geometry, stable detail selection, asynchronous filesystem success/failure")
    }
}
