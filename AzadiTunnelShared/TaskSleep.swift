import Foundation

/// `Task.sleep(for:)` requires iOS 16+; use nanoseconds for iOS 15 deployment target.
enum TaskSleep {
    static func seconds(_ seconds: Double) async throws {
        let ns = UInt64(max(0, seconds) * 1_000_000_000)
        try await Task.sleep(nanoseconds: ns)
    }

    static func milliseconds(_ ms: Double) async throws {
        let ns = UInt64(max(0, ms) * 1_000_000)
        try await Task.sleep(nanoseconds: ns)
    }
}
