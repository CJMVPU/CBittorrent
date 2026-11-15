import Foundation

@MainActor
struct JSONSettingsRepository: SettingsRepository {
    let url: URL

    func load() throws -> AppSettings {
        guard FileManager.default.fileExists(atPath: url.path) else { return try AppSettings().validated() }
        return try JSONDecoder().decode(AppSettings.self, from: Data(contentsOf: url)).validated()
    }

    func save(_ settings: AppSettings) async throws {
        let destination = url
        try await Task.detached(priority: .utility) {
            try JSONEncoder().encode(settings).write(to: destination, options: .atomic)
        }.value
    }
}

@MainActor
struct LocalDownloadDirectory: DownloadDirectory {
    func prepare(path: String) async throws {
        try await Task.detached(priority: .utility) {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        }.value
    }
}
