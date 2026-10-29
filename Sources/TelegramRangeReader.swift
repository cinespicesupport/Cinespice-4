import Foundation

/// TDLib has one download offset/limit per file. Queue complete read operations
/// for that file so concurrent VLC requests cannot replace each other's window.
actor TelegramRangeReader {
    private struct Pending {
        let id: UUID
        let task: Task<Data, Error>
    }
    private var pending: [Int32: Pending] = [:]

    func read(fileID: Int32, operation: @escaping @Sendable () async throws -> Data) async throws -> Data {
        let previous = pending[fileID]?.task
        let id = UUID()
        let task = Task<Data, Error> {
            if let previous { _ = try? await previous.value }
            try Task.checkCancellation()
            return try await operation()
        }
        pending[fileID] = Pending(id: id, task: task)
        defer { if pending[fileID]?.id == id { pending.removeValue(forKey: fileID) } }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
}

/// Return useful cached data promptly instead of waiting for a full 1 MB read.
/// Bound tiny partial reads while allowing the final bytes of a response.
enum StreamReadPolicy {
    static func readyCount(available: Int64, requested: Int) -> Int {
        guard requested > 0, available >= Int64(min(requested, 64 * 1024)) else { return 0 }
        return Int(min(available, Int64(requested)))
    }
}
