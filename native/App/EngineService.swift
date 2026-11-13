import Foundation

/// The C++ session and its bridge are accessed only through this serial queue.
final class EngineService: @unchecked Sendable {
    private let queue = DispatchQueue(label: "io.github.CJMVPU.CBittorrent.engine", qos: .utility)
    private var handle: OpaquePointer?

    init(profilePath: String, settings: AppSettings) throws {
        let data = try JSONEncoder().encode(settings.validated())
        let json = String(decoding: data, as: UTF8.self)
        var error: UnsafeMutablePointer<CChar>?
        handle = profilePath.withCString { profile in
            json.withCString { cbt_engine_create_configured(profile, $0, &error) }
        }
        if let error {
            let message = String(cString: error)
            cbt_string_free(error)
            if let handle { cbt_engine_destroy(handle) }
            handle = nil
            throw ClientError.message(message)
        }
        guard handle != nil else { throw ClientError.message("无法初始化下载引擎。") }
    }

    private func perform<T>(_ action: @escaping (OpaquePointer) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard let handle = self.handle else {
                    continuation.resume(throwing: ClientError.message("下载引擎已关闭。"))
                    return
                }
                do { continuation.resume(returning: try action(handle)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    private static func check(_ result: Int32, _ error: UnsafeMutablePointer<CChar>?) throws {
        defer { if let error { cbt_string_free(error) } }
        if result == 0 {
            throw ClientError.message(error.map { String(cString: $0) } ?? "下载引擎操作失败。")
        }
    }

    func snapshot() async throws -> EngineSnapshot {
        try await perform { handle in
            guard let json = cbt_engine_snapshot_json(handle) else {
                throw ClientError.message("无法读取下载任务。")
            }
            defer { cbt_string_free(json) }
            return try JSONDecoder().decode(EngineSnapshot.self, from: Data(String(cString: json).utf8))
        }
    }

    func add(source: String, savePath: String, paused: Bool) async throws {
        try await perform { handle in
            var error: UnsafeMutablePointer<CChar>?
            let result = source.withCString { sourcePointer in
                savePath.withCString { cbt_engine_add(handle, sourcePointer, $0, paused ? 1 : 0, &error) }
            }
            try Self.check(result, error)
        }
    }

    func pause(id: String) async throws {
        try await perform { handle in
            var error: UnsafeMutablePointer<CChar>?
            let result = id.withCString { cbt_engine_pause(handle, $0, &error) }
            try Self.check(result, error)
        }
    }

    func resume(id: String) async throws {
        try await perform { handle in
            var error: UnsafeMutablePointer<CChar>?
            let result = id.withCString { cbt_engine_resume(handle, $0, &error) }
            try Self.check(result, error)
        }
    }

    func remove(id: String, deleteFiles: Bool) async throws {
        try await perform { handle in
            var error: UnsafeMutablePointer<CChar>?
            let result = id.withCString { cbt_engine_remove(handle, $0, deleteFiles ? 1 : 0, &error) }
            try Self.check(result, error)
        }
    }

    func setFilePriority(id: String, index: Int, priority: Int) async throws {
        try await perform { handle in
            var error: UnsafeMutablePointer<CChar>?
            let result = id.withCString { cbt_engine_set_file_priority(handle, $0, Int32(index), Int32(priority), &error) }
            try Self.check(result, error)
        }
    }

    func setLimits(download: Int, upload: Int) async throws {
        try await perform { handle in
            var error: UnsafeMutablePointer<CChar>?
            let result = cbt_engine_set_limits(handle, Int32(clamping: download), Int32(clamping: upload), &error)
            try Self.check(result, error)
        }
    }

    func applySettings(_ settings: AppSettings) async throws {
        let data = try JSONEncoder().encode(settings.validated())
        let json = String(decoding: data, as: UTF8.self)
        try await perform { handle in
            var error: UnsafeMutablePointer<CChar>?
            let result = json.withCString { cbt_engine_apply_settings(handle, $0, &error) }
            try Self.check(result, error)
        }
    }

    /// Adds the saved default list without removing trackers already on a task.
    func applyDefaultTrackers() async throws -> Int {
        try await perform { handle in
            var error: UnsafeMutablePointer<CChar>?
            var changed: Int32 = 0
            let result = cbt_engine_apply_default_trackers(handle, &changed, &error)
            try Self.check(result, error)
            return Int(changed)
        }
    }

    func save() async throws {
        try await perform { handle in
            var error: UnsafeMutablePointer<CChar>?
            let result = cbt_engine_save(handle, &error)
            try Self.check(result, error)
        }
    }

    func close() async throws {
        // Keep the engine alive when saving fails so the user can retry safely.
        try await save()
        await withCheckedContinuation { continuation in
            queue.async {
                if let handle = self.handle { cbt_engine_destroy(handle) }
                self.handle = nil
                continuation.resume()
            }
        }
    }
}
