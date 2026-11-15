import Foundation

/// Filesystem calls may block on mounted volumes; never perform them in AppKit callbacks.
enum FileSystemService {
    struct Entry: Sendable {
        let url: URL
        let isDirectory: Bool
    }

    static func list(_ url: URL, completion: @escaping @MainActor (Result<[Entry], Error>) -> Void) {
        Task.detached(priority: .userInitiated) {
            let result = Result {
                try FileManager.default.contentsOfDirectory(at: url,
                    includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
                    .map { Entry(url: $0, isDirectory: try $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true) }
                    .sorted {
                        if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                        return $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending
                    }
            }
            await completion(result)
        }
    }

    static func freeSpace(path: String, completion: @escaping @MainActor (Int64?) -> Void) {
        Task.detached(priority: .utility) {
            let attributes = try? FileManager.default.attributesOfFileSystem(forPath: path)
            let bytes = (attributes?[.systemFreeSize] as? NSNumber)?.int64Value
            await completion(bytes)
        }
    }

    static func fileSize(_ url: URL, completion: @escaping @MainActor (Result<Int64, Error>) -> Void) {
        Task.detached(priority: .userInitiated) {
            let result = Result { Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
            await completion(result)
        }
    }

    static func createDirectory(_ url: URL, completion: @escaping @MainActor (Result<Void, Error>) -> Void) {
        Task.detached(priority: .userInitiated) {
            let result = Result { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false) }
            await completion(result)
        }
    }
}
