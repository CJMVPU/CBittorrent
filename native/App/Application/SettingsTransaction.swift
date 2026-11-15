import Foundation

/// Persist before applying policy, so a disk failure cannot stop live tasks.
enum SettingsTransaction {
    static func commit(persist: () async throws -> Void, apply: () async throws -> Void,
                       rollback: () async throws -> Void) async throws {
        try await persist()
        do { try await apply() }
        catch {
            let original = error
            do { try await rollback() }
            catch { throw ClientError.message("设置应用和恢复失败：\(original.localizedDescription)\n\(error.localizedDescription)") }
            throw original
        }
    }
}
