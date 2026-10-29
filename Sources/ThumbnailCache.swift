import Foundation

/// Contains image bytes only. Never receives a Telegram session or media path.
actor ThumbnailCache {
    let directory: URL
    let budget: Int
    init(directory: URL, budget: Int = 40 * 1024 * 1024) { self.directory = directory; self.budget = max(0, budget) }

    private func file(_ key: String) throws -> URL {
        guard !key.isEmpty, key.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) || $0 == 95 || $0 == 45 }) else { throw CocoaError(.fileWriteInvalidFileName) }
        return directory.appendingPathComponent(key).appendingPathExtension("thumb")
    }
    func read(_ key: String) throws -> Data? {
        let url = try file(key)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return data
    }
    func write(_ data: Data, key: String) throws {
        guard data.count <= min(budget, 2 * 1024 * 1024) else { throw CocoaError(.fileWriteOutOfSpace) }
        let url = try file(key)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        try trim()
    }
    private func files() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]).filter { $0.pathExtension == "thumb" }
    }
    func bytes() throws -> Int { try files().reduce(0) { $0 + (try $1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) } }
    private func trim() throws {
        let entries = try files().map { url -> (URL, Int, Date) in
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            return (url, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
        }.sorted { $0.2 < $1.2 }
        var total = entries.reduce(0) { $0 + $1.1 }
        for entry in entries where total > budget { try FileManager.default.removeItem(at: entry.0); total -= entry.1 }
    }
    func clear() throws { for url in try files() { try FileManager.default.removeItem(at: url) } }
}
