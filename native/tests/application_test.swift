import Foundation

final class FakeEngine: TransferEngine {
    var calls: [String] = []
    var value = EngineSnapshot()
    var rejected = Set<String>()
    var gate: CheckedContinuation<Void, Never>?
    var suspendNext = false
    private func record(_ call: String) async throws {
        calls.append(call)
        if suspendNext {
            suspendNext = false
            await withCheckedContinuation { gate = $0 }
        }
        if rejected.contains(call) { throw ClientError.message(call) }
    }
    func snapshot() async throws -> EngineSnapshot { try await record("snapshot"); return value }
    func detail(id: String) async throws -> TorrentSnapshot { throw ClientError.message("missing") }
    func add(source: String, savePath: String, paused: Bool) async throws { try await record("add:\(source)") }
    func prepareMetadata(source: String) async throws -> String { try await record("preview:\(source)"); return "preview-id" }
    func cancelMetadata(id: String) async throws { try await record("cancel:\(id)") }
    func confirmMetadata(id: String, savePath: String, paused: Bool) async throws { try await record("confirm:\(id)") }
    func pause(id: String) async throws { try await record("pause:\(id)") }
    func resume(id: String) async throws { try await record("resume:\(id)") }
    func remove(id: String, deleteFiles: Bool) async throws { try await record("remove:\(id):\(deleteFiles)") }
    func setFilePriority(id: String, index: Int, priority: Int) async throws { try await record("priority") }
    func applySettings(_ settings: AppSettings) async throws { try await record("settings:\(settings.listenPort)") }
    func applyDefaultTrackers() async throws -> Int { try await record("trackers"); return 2 }
    func save(all: Bool) async throws { try await record("save") }
    func close() async throws { try await record("close") }
}

@MainActor
final class FakeRepository: SettingsRepository {
    var value = AppSettings()
    var failSave = false
    func load() throws -> AppSettings { value }
    func save(_ settings: AppSettings) throws {
        if failSave { throw ClientError.message("disk") }
        value = settings
    }
}

@MainActor
final class FakeEffects: DownloadDirectory, CompletionNotifier {
    var completedIDs: [String] = []
    func prepare(path: String) throws { }
    func requestAuthorization() async { }
    func completed(_ torrent: TorrentSnapshot) async { completedIDs.append(torrent.id) }
}

@main
struct ApplicationTests {
    @MainActor
    static func main() async throws {
        func expect(_ condition: Bool, _ message: String) throws {
            if !condition { throw ClientError.message(message) }
        }
        func fails(_ operation: () async throws -> Void) async throws {
            do { try await operation() }
            catch is ClientError { return }
            throw NSError(domain: "ExpectedFailure", code: 1)
        }
        let engine = FakeEngine()
        let repository = FakeRepository()
        let effects = FakeEffects()
        var settings = AppSettings()
        settings.notifyOnCompletion = true
        let app = TransferApplication(engine: engine, repository: repository,
            directory: effects, notifier: effects, settings: settings)

        let pendingID = try await app.prepareMetadata(source: "magnet:test")
        try expect(engine.calls == ["preview:magnet:test"], "Preview must not save a transfer")
        engine.calls = []
        try await app.confirmMetadata(id: pendingID)
        try expect(engine.calls == ["confirm:preview-id", "save"], "Confirmed preview must persist")
        engine.calls = []
        try await app.cancelMetadata(id: pendingID)
        try expect(engine.calls == ["cancel:preview-id"], "Cancel must not add or save a task")
        engine.calls = []
        engine.rejected = ["add:bad"]
        let result = try await app.add(sources: ["good", "bad", "never"])
        try expect(result.accepted == ["good"] && result.failure != nil, "Partial addition lost accepted sources")
        try expect(engine.calls == ["add:good", "add:bad", "save"], "Partial addition was not flushed")
        engine.calls = []
        engine.rejected = ["pause:bad", "save"]
        do { try await app.execute(.pause(["good", "bad"])) }
        catch {
            try expect(error.localizedDescription.contains("pause:bad") && error.localizedDescription.contains("save"),
                       "Batch failure hid the persistence failure")
        }
        try expect(engine.calls == ["pause:good", "pause:bad", "save"], "Partial batch was not flushed")
        engine.calls = []
        engine.rejected = []
        try await fails { try await app.execute(.priority(id: "good", index: Int.max, priority: 7)) }
        try expect(!engine.calls.contains("priority"), "Out-of-range index reached engine")
        engine.calls = []
        repository.failSave = true
        var candidate = settings
        candidate.listenPort = 1234
        try await fails { try await app.updateSettings(candidate) }
        try expect(engine.calls.isEmpty && app.settings == settings, "Disk failure changed live settings")
        repository.failSave = false
        engine.rejected = ["settings:1234"]
        try await fails { try await app.updateSettings(candidate) }
        try expect(engine.calls == ["settings:1234", "settings:0"] && repository.value == settings,
                   "Engine rejection did not roll back settings")
        engine.rejected = []
        try await app.updateSettings(candidate)
        try expect(app.settings == candidate && repository.value == candidate, "Successful settings were not committed")

        let fixture = Data(#"{"id":"one","name":"Alpha","state":"downloading","progress":0.5,"totalSize":10,"downloaded":5,"uploaded":0,"downloadRate":1,"uploadRate":0,"eta":5,"ratio":0,"peers":2,"seeds":1,"savePath":"/tmp","error":"","files":[],"trackers":[]}"#.utf8)
        var torrent = try JSONDecoder().decode(TorrentSnapshot.self, from: fixture)
        engine.value.torrents = [torrent]
        _ = try await app.snapshot()
        torrent.progress = 1
        engine.value.torrents = [torrent]
        _ = try await app.snapshot()
        _ = try await app.snapshot()
        try expect(effects.completedIDs == ["one"], "Completion event was lost or repeated")

        // Suspend inside a command and start shutdown. Closing must drain the
        // entire command plus flush, and reject newly arriving mutations.
        engine.calls = []
        engine.suspendNext = true
        let command = Task { try await app.execute(.pause(["one", "two"])) }
        while engine.gate == nil { await Task.yield() }
        let close = Task { try await app.shutdown() }
        // A marker task on the same actor allows shutdown to reach its wait.
        await Task { @MainActor in }.value
        try await fails { try await app.execute(.resume(["late"])) }
        try expect(engine.calls == ["pause:one"], "Shutdown interleaved with an active command")
        engine.gate?.resume(); engine.gate = nil
        try await command.value
        try await close.value
        try expect(engine.calls == ["pause:one", "pause:two", "save", "close"], "Shutdown did not drain accepted work")
        try await fails { _ = try await app.snapshot() }

        let retryEngine = FakeEngine()
        let retry = TransferApplication(engine: retryEngine, repository: repository,
            directory: effects, notifier: effects, settings: settings)
        retryEngine.rejected = ["close"]
        try await fails { try await retry.shutdown() }
        retryEngine.rejected = []
        try await retry.execute(.resume(["one"]))
        try await retry.shutdown()
        try expect(retryEngine.calls == ["close", "resume:one", "save", "close"], "Failed shutdown prevented recovery")
        print("PASS: application batches, persistence errors, validation, settings rollback, completion events, shutdown ordering and retry")
    }
}
