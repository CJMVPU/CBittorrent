import Foundation

@main
struct StorageTests {
    @MainActor
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = JSONSettingsRepository(url: root.appendingPathComponent("settings.json"))
        let defaults = try repository.load()
        var settings = defaults
        settings.downloadPath = root.appendingPathComponent("downloads").path
        settings.listenPort = 43123
        try await repository.save(settings)
        let restored = try repository.load()
        precondition(restored == settings, "Preferences must round-trip through the concrete adapter")
        try await LocalDownloadDirectory().prepare(path: settings.downloadPath)
        precondition(FileManager.default.fileExists(atPath: settings.downloadPath))
        let invalid = JSONSettingsRepository(url: root.appendingPathComponent("absent/settings.json"))
        do {
            try await invalid.save(defaults)
            preconditionFailure("Missing parent must report a write failure")
        } catch { }
        let retained = try repository.load()
        precondition(retained == settings, "Failed write touched an unrelated settings store")
        try Data("broken".utf8).write(to: repository.url)
        do {
            _ = try repository.load()
            preconditionFailure("Corrupt existing preferences must not silently reset")
        } catch is DecodingError { }
        do {
            try await LocalDownloadDirectory().prepare(path: repository.url.path)
            preconditionFailure("A file must not be accepted as a download directory")
        } catch { }
        print("PASS: concrete asynchronous settings storage, failed writes, corrupt input and directory failures")
    }
}
