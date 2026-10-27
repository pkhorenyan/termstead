import Foundation

/// Work that blocks a thread — a process to wait for, a file to copy, a
/// socket to connect — run on a GCD thread rather than in a task.
///
/// `Task.detached` runs on Swift's shared pool, which has a thread per core
/// and never adds one for a thread that blocks. An `sftp` transfer held its
/// thread for as long as it ran; a few at once left nothing for the rest of
/// the app's async work, and a local terminal's Files tab sat loading for
/// more than fifteen seconds beside them (the test suite caught it).
enum BlockingWork {
    static func wait<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: work()) }
        }
    }

    static func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try work() })
            }
        }
    }
}
