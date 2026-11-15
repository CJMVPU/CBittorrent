import Foundation

@MainActor
struct JSONSettingsRepository: SettingsRepository {
    let url: URL

    func load() throws -> AppSettings {
        guard FileManager.default.fileExists(atPath: url.path) else { return try AppSettings().validated() }
        return try JSONDecoder().decode(AppSettings.self, from: Data(contentsOf: url)).validated()
    }

    func save(_ settings: AppSettings) throws {
        try JSONEncoder().encode(settings).write(to: url, options: .atomic)
    }
}

@MainActor
struct LocalDownloadDirectory: DownloadDirectory {
    func prepare(path: String) throws {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }
}
