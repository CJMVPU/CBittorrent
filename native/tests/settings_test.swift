import Foundation

@main
struct SettingsTests {
    static func main() async throws {
        func expect(_ condition: Bool, _ message: String) throws {
            if !condition { throw ClientError.message(message) }
        }
        let legacy = Data(#"{"downloadPath":"/tmp/cb-settings-legacy","downloadLimitKB":128,"addPaused":true,"closeKeepsTransfers":false}"#.utf8)
        let migrated = try JSONDecoder().decode(AppSettings.self, from: legacy).validated()
        try expect(migrated.downloadLimitKB == 128 && migrated.addPaused && !migrated.closeKeepsTransfers,
                   "Existing settings were lost during schema migration")
        try expect(migrated.enableDHT && migrated.queueEnabled && migrated.listenPort == 0 && !migrated.autoAddTrackers && migrated.defaultTrackers.isEmpty,
                   "New setting defaults did not populate")
        var configured = migrated
        configured.listenPort = 50123
        configured.enableDHT = false
        configured.seedRatioLimit = 1.25
        configured.proxyType = 1
        configured.proxyHost = "  localhost  "
        configured.proxyPort = 1080
        configured.autoAddTrackers = true
        configured.defaultTrackers = "  https://127.0.0.1:9/announce  \n\nhttps://127.0.0.1:9/announce\r\nudp://127.0.0.1:9/announce"
        let normalized = try configured.validated()
        try expect(normalized.defaultTrackers == "https://127.0.0.1:9/announce\nudp://127.0.0.1:9/announce", "Tracker whitespace or duplicate normalization failed")
        try expect(normalized.proxyHost == "localhost", "Proxy host was not normalized")
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(normalized))
        try expect(decoded == normalized, "Expanded settings did not round-trip")
        let invalid: [(inout AppSettings) -> Void] = [
            { $0.listenPort = 65536 }, { $0.downloadLimitKB = -1 },
            { $0.uploadLimitKB = Int.max }, { $0.maxConnections = 1 },
            { $0.maxActiveDownloads = 0 }, { $0.seedRatioLimit = .nan },
            { $0.seedTimeLimitMinutes = -1 }, { $0.transportMode = 3 },
            { $0.proxyHost = "http://localhost" }, { $0.proxyPort = 0 },
            { $0.defaultTrackers = "file:///tmp/tracker" },
            { $0.defaultTrackers = "https://127.0.0.1:65536/announce" },
            { $0.defaultTrackers = "http://127.0.0.1:0/announce" },
            { $0.defaultTrackers = "https://127.0.0.1:abc/announce" },
            { $0.defaultTrackers = "http:///announce" },
            { $0.defaultTrackers = "http://127.0.0.1/a b" },
            { $0.defaultTrackers = "http://127.0.0.1/\0announce" }
        ]
        for change in invalid {
            var candidate = normalized
            change(&candidate)
            do {
                _ = try candidate.validated()
                throw NSError(domain: "ExpectedValidationFailure", code: 1)
            } catch is ClientError { }
        }
        do {
            _ = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"enableDHT":"yes"}"#.utf8))
            throw ClientError.message("Corrupt values were silently accepted")
        } catch is DecodingError { }
        let fixture = Data(#"{"id":"one","name":"Alpha","state":"downloading","progress":0.5,"totalSize":10,"downloaded":5,"uploaded":0,"downloadRate":1,"uploadRate":0,"eta":5,"ratio":0,"peers":2,"seeds":1,"savePath":"/tmp","error":"","files":[],"trackers":[]}"#.utf8)
        let active = try JSONDecoder().decode(TorrentSnapshot.self, from: fixture)
        var stopped = active
        stopped.id = "two"; stopped.name = "Beta"; stopped.state = "paused"; stopped.peers = 0
        let all = [active, stopped]
        let visible = TransferSelection.visible(torrents: all, filter: .downloading, search: "")
        try expect(TransferSelection.reconcile(["one", "two"], visible: visible) == ["one"], "Hidden tasks remained selected")
        try expect(TransferSelection.reconcile(["one"], visible: TransferSelection.visible(torrents: all, filter: .all, search: "Beta")).isEmpty,
                   "Search-hidden task remained selected")
        let summary = TransferSummary(torrents: all)
        try expect(summary.peerCount == 2 && summary.count(for: .all) == 2 && summary.count(for: .paused) == 1,
                   "Shared transfer summary disagrees with filter semantics")
        var applied = false
        var rolledBack = false
        do {
            try await SettingsTransaction.commit {
                throw ClientError.message("Simulated disk failure")
            } apply: { applied = true } rollback: { rolledBack = true }
            throw NSError(domain: "ExpectedDiskFailure", code: 1)
        } catch is ClientError { }
        try expect(!applied && !rolledBack, "Disk failure touched live task policy")
        var persisted = "old"
        do {
            try await SettingsTransaction.commit { persisted = "new" } apply: {
                throw ClientError.message("Simulated engine rejection")
            } rollback: { persisted = "old" }
            throw NSError(domain: "ExpectedEngineFailure", code: 1)
        } catch is ClientError { }
        try expect(persisted == "old", "Engine rejection did not restore persisted settings")
        try await SettingsTransaction.commit { persisted = "new" } apply: { applied = true } rollback: { persisted = "old" }
        try expect(applied && persisted == "new", "Successful settings transaction failed")
        print("PASS: legacy settings migration, default values, normalization, persistence, invalid-input rejection, hidden selection, shared summaries and settings failure transactions")
    }
}
