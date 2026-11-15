import Foundation

/// The sole place where application ports are connected to production adapters.
@MainActor
enum AppComposition {
    static func makeStore(profile: URL) throws -> AppStore {
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        let repository = JSONSettingsRepository(url: profile.appendingPathComponent("settings.json"))
        let settings = try repository.load()
        let engine = try EngineService(profilePath: profile.appendingPathComponent("Session").path, settings: settings)
        let application = TransferApplication(engine: engine, repository: repository,
            directory: LocalDownloadDirectory(), notifier: SystemCompletionNotifier(), settings: settings)
        return AppStore(application: application)
    }
}
