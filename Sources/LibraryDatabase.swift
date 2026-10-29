import Foundation
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif

/// One instance per Telegram account. Every query and disk write runs on this actor.
actor LibraryDatabase {
    private let url: URL
    private var connection: OpaquePointer?
    private var revision = 0
    private var cachedSnapshot: LibrarySnapshot?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(url: URL) { self.url = url }
    deinit { if let connection { sqlite3_close(connection) } }

    private func open() throws -> OpaquePointer {
        if let connection { return connection }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            throw failure("Open library")
        }
        connection = db
        sqlite3_busy_timeout(db, 3000)
        do {
            let version = try rows("PRAGMA user_version").first.flatMap { Int($0[0]) } ?? 0
            guard version <= 3 else { throw failure("Library requires a newer app version") }
            try execute("PRAGMA journal_mode=WAL")
            try execute("CREATE TABLE IF NOT EXISTS videos (id TEXT PRIMARY KEY, payload TEXT NOT NULL)")
            try execute("CREATE TABLE IF NOT EXISTS collections (id TEXT PRIMARY KEY, payload TEXT NOT NULL, selected INTEGER NOT NULL DEFAULT 0)")
            try execute("CREATE TABLE IF NOT EXISTS history (id TEXT PRIMARY KEY, payload TEXT NOT NULL)")
            try execute("CREATE TABLE IF NOT EXISTS collection_indexes (id TEXT PRIMARY KEY, payload TEXT NOT NULL)")
            try execute("CREATE TABLE IF NOT EXISTS saved_lists (list TEXT NOT NULL, video_id TEXT NOT NULL, PRIMARY KEY(list, video_id))")
            try execute("PRAGMA user_version=3")
        } catch {
            sqlite3_close(db); connection = nil
            throw error
        }
        return db
    }

    private func failure(_ operation: String) -> NSError {
        NSError(domain: "Tevee.Library", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(operation) failed. Your existing library has been kept."])
    }

    private func statement(_ sql: String, _ arguments: [String]) throws -> OpaquePointer {
        let db = try open()
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw failure("Prepare library query") }
        for (index, value) in arguments.enumerated() {
            let status = value.withCString { sqlite3_bind_text(statement, Int32(index + 1), $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
            guard status == SQLITE_OK else { sqlite3_finalize(statement); throw failure("Bind library query") }
        }
        return statement
    }

    private func execute(_ sql: String, _ arguments: [String] = []) throws {
        let stmt = try statement(sql, arguments)
        defer { sqlite3_finalize(stmt) }
        var result = sqlite3_step(stmt)
        while result == SQLITE_ROW { result = sqlite3_step(stmt) }
        guard result == SQLITE_DONE else { throw failure("Save library") }
        revision += 1
        cachedSnapshot = nil
    }

    private func rows(_ sql: String, _ arguments: [String] = []) throws -> [[String]] {
        let stmt = try statement(sql, arguments)
        defer { sqlite3_finalize(stmt) }
        var result: [[String]] = []
        var status = sqlite3_step(stmt)
        while status == SQLITE_ROW {
            result.append((0..<sqlite3_column_count(stmt)).map { index in
                sqlite3_column_text(stmt, index).map { String(cString: $0) } ?? ""
            })
            status = sqlite3_step(stmt)
        }
        guard status == SQLITE_DONE else { throw failure("Read library") }
        return result
    }

    private func json<T: Encodable>(_ value: T) throws -> String { String(decoding: try encoder.encode(value), as: UTF8.self) }
    private func decode<T: Decodable>(_ type: T.Type, _ text: String) throws -> T { try decoder.decode(type, from: Data(text.utf8)) }

    func snapshot() throws -> LibrarySnapshot {
        if let cachedSnapshot { return cachedSnapshot }
        var snapshot = LibrarySnapshot()
        snapshot.videos = try rows("SELECT payload FROM videos").map { try decode(TelegramVideo.self, $0[0]) }
        for row in try rows("SELECT id,payload,selected FROM collections") {
            snapshot.collections.append(try decode(TelegramChat.self, row[1]))
            if row[2] == "1", let id = Int64(row[0]) { snapshot.selected.insert(id) }
        }
        for row in try rows("SELECT id,payload FROM history") { snapshot.history[row[0]] = try decode(WatchProgress.self, row[1]) }
        for row in try rows("SELECT id,payload FROM collection_indexes") {
            if let id = Int64(row[0]) { snapshot.indexes[id] = try decode(CollectionIndex.self, row[1]) }
        }
        for row in try rows("SELECT list,video_id FROM saved_lists") { snapshot.savedLists[row[0], default: []].insert(row[1]) }
        snapshot.revision = revision
        snapshot.browsing = LibraryBrowsing(snapshot: snapshot)
        cachedSnapshot = snapshot
        return snapshot
    }

    func save(videos: [TelegramVideo]) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            for video in videos {
                try execute("INSERT INTO videos(id,payload) VALUES(?,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload", [video.id, try json(video)])
            }
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }

    /// Metadata and the next page cursor commit together; a failed save is retriable.
    func savePage(videos: [TelegramVideo], chatID: Int64, index: CollectionIndex) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            for video in videos {
                try execute("INSERT INTO videos(id,payload) VALUES(?,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload", [video.id, try json(video)])
            }
            try execute("INSERT INTO collection_indexes(id,payload) VALUES(?,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload", [String(chatID), try json(index)])
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }

    func save(collection: TelegramChat, selectedByDefault: Bool = false) throws {
        try execute("INSERT INTO collections(id,payload,selected) VALUES(?,?,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload",
                    [String(collection.id), try json(collection), selectedByDefault ? "1" : "0"])
    }

    func save(collections: [TelegramChat]) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            for chat in collections { try save(collection: chat) }
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }

    func select(collectionID: Int64, selected: Bool) throws {
        try execute("UPDATE collections SET selected=? WHERE id=?", [selected ? "1" : "0", String(collectionID)])
    }

    func save(progress: WatchProgress, video: TelegramVideo) throws {
        if let row = try rows("SELECT payload FROM history WHERE id=?", [video.id]).first,
           try decode(WatchProgress.self, row[0]).updatedAt > progress.updatedAt { return }
        var cached = cachedSnapshot
        try execute("BEGIN IMMEDIATE")
        do {
            try execute("INSERT INTO videos(id,payload) VALUES(?,?) ON CONFLICT(id) DO NOTHING", [video.id, try json(video)])
            try execute("INSERT INTO history(id,payload) VALUES(?,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload", [video.id, try json(progress)])
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
        if var value = cached {
            let known = value.videos.contains { $0.id == video.id }
            if !known { value.videos.append(video) }
            value.history[video.id] = progress; value.revision = revision
            if known { value.browsing.updateHistory(value.history) }
            else { value.browsing = LibraryBrowsing(snapshot: value) }
            cached = value
        }
        cachedSnapshot = cached
    }

    /// Save metadata with membership so remote search results survive a restart.
    func setSaved(_ video: TelegramVideo, list: String, saved: Bool) throws {
        let cached = cachedSnapshot
        try execute("BEGIN IMMEDIATE")
        do {
            if saved {
                try execute("INSERT INTO videos(id,payload) VALUES(?,?) ON CONFLICT(id) DO NOTHING", [video.id, try json(video)])
                try execute("INSERT OR IGNORE INTO saved_lists(list,video_id) VALUES(?,?)", [list, video.id])
            } else {
                try execute("DELETE FROM saved_lists WHERE list=? AND video_id=?", [list, video.id])
            }
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
        if var value = cached {
            if saved {
                value.savedLists[list, default: []].insert(video.id)
                if !value.videos.contains(where: { $0.id == video.id }) {
                    value.videos.append(video); value.browsing = LibraryBrowsing(snapshot: value)
                }
            } else { value.savedLists[list]?.remove(video.id) }
            value.revision = revision; cachedSnapshot = value
        }
    }

    func clearHistory(videoID: String? = nil) throws {
        if let videoID { try execute("DELETE FROM history WHERE id=?", [videoID]) }
        else { try execute("DELETE FROM history") }
    }

    func saveCompletedFile(_ status: LocalFileStatus) throws {
        guard status.complete else { return }
        let videos = try snapshot().videos.filter { $0.fileID == status.id }.map { video -> TelegramVideo in
            var copy = video
            copy.size = status.size; copy.localPath = status.path
            copy.downloadedBytes = status.downloaded; copy.isDownloaded = true
            return copy
        }
        try save(videos: videos)
    }

    func invalidateMediaCache() throws {
        var videos = try snapshot().videos
        for index in videos.indices { videos[index].localPath = ""; videos[index].downloadedBytes = 0; videos[index].isDownloaded = false }
        try save(videos: videos)
    }
}
