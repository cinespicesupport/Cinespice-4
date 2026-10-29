import XCTest
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif
@testable import TeveeStreaming

/// Synthetic Telegram metadata transport; never authenticates or downloads media.
private actor DiscoveryFixture {
    var calls: [[String: Any]] = []
    var loaded: [String: Int] = [:]
    let shortPages: Bool
    var failOnce: Int64?
    init(shortPages: Bool = false, failOnce: Int64? = nil) { self.shortPages = shortPages; self.failOnce = failOnce }
    func request(_ value: [String: Any]) throws -> [String: Any] {
        calls.append(value)
        let type = value["@type"] as? String ?? ""
        let list = (value["chat_list"] as? [String: Any])?["@type"] as? String ?? ""
        let ids = list == "chatListArchive" ? Array(Int64(101)...110) : Array(Int64(1)...75)
        switch type {
        case "loadChats":
            let count = loaded[list] ?? 0
            if count >= ids.count { throw NSError(domain: "TDLib", code: 404) }
            loaded[list] = min(ids.count, count + (shortPages ? 5 : 30)); return [:]
        case "getChats": return ["chat_ids": Array(ids.prefix(min(loaded[list] ?? 0, value["limit"] as? Int ?? 0)))]
        case "searchChatsOnServer": return ["chat_ids": [Int64(68), 2]]
        case "searchChats": return ["chat_ids": [Int64(2), 1]]
        case "getChat":
            let id = value["chat_id"] as! Int64
            if failOnce == id { failOnce = nil; throw URLError(.networkConnectionLost) }
            return ["id": id, "title": "Synthetic channel \(id)", "type": ["@type": "chatTypeSupergroup", "supergroup_id": id + 1000, "is_channel": true]]
        case "getSupergroup":
            let id = (value["supergroup_id"] as! Int64) - 1000
            return ["date": id == 2 ? Int64(100) : Int64(500), "status": ["@type": [1, 2, 68].contains(id) ? "chatMemberStatusCreator" : "chatMemberStatusAdministrator"]]
        default: XCTFail("Unexpected operation \(type)"); return [:]
        }
    }
    func requestedChats() -> [Int64] { calls.filter { $0["@type"] as? String == "getChat" }.compactMap { $0["chat_id"] as? Int64 } }
    func searchFilters() -> [String] {
        calls.filter { ["searchChats", "searchChatsOnServer"].contains($0["@type"] as? String ?? "") }.compactMap { ($0["type_filter"] as? [String: String])?["@type"] }
    }
    func operationTypes() -> [String] { calls.compactMap { $0["@type"] as? String } }
}

final class TelegramDiscoveryTests: XCTestCase {
    func testDiscoveryIsBoundedMetadataOnlyAndChecksOwnership() async throws {
        let fixture = DiscoveryFixture()
        let reader = TelegramDiscovery { try await fixture.request($0) }
        let page = try await reader.next(cached: [], accountID: 900)
        XCTAssertEqual(page.chats.count, 30)
        XCTAssertEqual(page.chats.prefix(2).map(\.id), [2, 1])
        XCTAssertTrue(page.hasMore)
        let types = await fixture.operationTypes()
        XCTAssertFalse(types.contains("searchChatMessages"))
        XCTAssertFalse(types.contains("downloadFile"))
        XCTAssertEqual(page.chats.first(where: { $0.id == 3 })?.isOwner, false)
    }
    func testMainArchivePaginationDoesNotResolveCachedChatsAgain() async throws {
        let fixture = DiscoveryFixture()
        let reader = TelegramDiscovery { try await fixture.request($0) }
        var cached: [TelegramChat] = []
        for _ in 0..<3 {
            let page = try await reader.next(cached: cached, accountID: 900)
            XCTAssertLessThanOrEqual(page.chats.count, 30)
            cached += page.chats
        }
        let ids = await fixture.requestedChats()
        XCTAssertEqual(ids.count, Set(ids).count)
        XCTAssertEqual(ids.count, 70)
        XCTAssertTrue(cached.contains(where: { $0.id == 101 }))
        // A new app session can reuse metadata instead of resolving known IDs.
        let reopened = TelegramDiscovery { try await fixture.request($0) }
        let page = try await reopened.next(cached: cached, accountID: 900)
        XCTAssertTrue(page.chats.isEmpty)
        let after = await fixture.requestedChats()
        XCTAssertEqual(ids, after)
    }
    func testServerSearchFindsUnscannedOwnedChannelAndDeduplicatesResults() async throws {
        let fixture = DiscoveryFixture()
        let reader = TelegramDiscovery { try await fixture.request($0) }
        let results = try await reader.search("Synthetic", accountID: 900)
        XCTAssertEqual(Set(results.map(\.id)), [1, 2, 68])
        XCTAssertEqual(results.first(where: { $0.id == 68 })?.isOwner, true)
        let ids = await fixture.requestedChats()
        XCTAssertEqual(ids.count, 3)
        let filters = await fixture.searchFilters()
        XCTAssertEqual(filters, ["searchChatTypeFilterChannel", "searchChatTypeFilterChannel"])
    }
    func testShortPageIsNotExhaustionAndFailedBatchCanRetry() async throws {
        let fixture = DiscoveryFixture(shortPages: true)
        let reader = TelegramDiscovery { try await fixture.request($0) }
        let first = try await reader.next(cached: [], accountID: nil)
        XCTAssertEqual(first.chats.count, 5)
        XCTAssertTrue(first.hasMore)
        let failures = DiscoveryFixture(failOnce: 3)
        let retry = TelegramDiscovery { try await failures.request($0) }
        do { _ = try await retry.next(cached: [], accountID: nil); XCTFail("Expected transport failure") } catch { }
        let recovered = try await retry.next(cached: [], accountID: nil)
        XCTAssertEqual(Set(recovered.chats.map(\.id)), Set(Int64(1)...30))
    }
    func testUsernameSearchDoesNotHideServerMatches() {
        let channel = TelegramChat(id: 1, title: "Synthetic film archive", type: "chatTypeSupergroup", isOwner: true, isChannel: true, usernames: ["synthetic_movies"])
        XCTAssertTrue(channel.matches("@synthetic_movies"))
        XCTAssertTrue(channel.matches(" film "))
        XCTAssertFalse(channel.matches("unrelated"))
    }
    func testOldChatJSONLoadsAndCreatorIsDifferentFromAdministrator() throws {
        let legacy = Data(#"{"id":1,"title":"Synthetic","type":"chatTypeSupergroup"}"#.utf8)
        let decoded = try JSONDecoder().decode(TelegramChat.self, from: legacy)
        XCTAssertNil(decoded.isOwner)
        let data: [String: Any] = ["id": Int64(1), "title": "Synthetic", "type": ["@type": "chatTypeSupergroup", "is_channel": true]]
        let owner = try XCTUnwrap(TelegramChat.from(data, group: ["date": Int64(20), "status": ["@type": "chatMemberStatusCreator"]]))
        let admin = try XCTUnwrap(TelegramChat.from(data, group: ["status": ["@type": "chatMemberStatusAdministrator"]]))
        XCTAssertEqual(owner.isOwner, true); XCTAssertEqual(admin.isOwner, false)
        XCTAssertEqual(owner.telegramDate, 20)
    }
}

final class MediaIndexTests: XCTestCase {
    func testPageAndMetadataSurviveReopenWithoutResettingExhaustedFilters() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("library.sqlite")
        let db = LibraryDatabase(url: url)
        let item = TelegramVideo(messageID: 7, chatID: 1, fileID: 9, title: "Synthetic.mkv", size: 200, mimeType: "video/x-matroska", duration: 120, localPath: "", downloadedBytes: 0, isDownloaded: false, fileName: "Synthetic.mkv", remoteUniqueID: "synthetic-unique")
        var index = CollectionIndex()
        index.advance(filter: "searchMessagesFilterVideo", from: 0, next: 99)
        index.advance(filter: "searchMessagesFilterDocument", from: 0, next: 0)
        try await db.savePage(videos: [item], chatID: 1, index: index)
        // Re-indexing the same message replaces its metadata, preserving identity/history.
        try await db.save(progress: WatchProgress(videoID: item.id, position: 30, duration: 120), video: item)
        try await db.savePage(videos: [item], chatID: 1, index: index)
        let result = try await LibraryDatabase(url: url).snapshot()
        XCTAssertEqual(result.videos.count, 1)
        XCTAssertEqual(result.videos[0].remoteUniqueID, "synthetic-unique")
        XCTAssertEqual(result.indexes[1], index)
        XCTAssertNil(result.indexes[1]?.cursors["searchMessagesFilterDocument"])
        XCTAssertEqual(result.history[item.id]?.position, 30)
    }
    func testStableThumbnailKeySurvivesFileIDChangesAndLegacyMediaDecodes() async throws {
        var item = TelegramVideo(messageID: 7, chatID: 1, fileID: 9, title: "Synthetic.mkv", size: 200, mimeType: "video/x-matroska", duration: 120, localPath: "", downloadedBytes: 0, isDownloaded: false, thumbnailFileID: 10, thumbnailUniqueID: "synthetic/a+b")
        let key = item.thumbnailKey
        item.thumbnailFileID = 20
        XCTAssertEqual(item.thumbnailKey, key)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ThumbnailCache(directory: directory)
        try await cache.write(Data([1, 2, 3]), key: key)
        let reused = try await cache.read(item.thumbnailKey)
        XCTAssertEqual(reused, Data([1, 2, 3]))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(item)) as? [String: Any])
        for field in ["fileName", "caption", "remoteUniqueID", "thumbnailUniqueID", "thumbnailRemoteID", "mediaKind"] { json.removeValue(forKey: field) }
        let legacy = try JSONDecoder().decode(TelegramVideo.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(legacy.id, item.id)
        XCTAssertNil(legacy.fileName)
    }
    func testVideoDocumentsKeepFilenamesAndRejectAudio() throws {
        for name in ["Synthetic.mxf", "Synthetic.rmvb", "Synthetic.MKV"] {
            let message: [String: Any] = ["id": Int64(1), "content": ["caption": ["text": "Synthetic caption"], "document": ["file_name": name, "mime_type": "application/octet-stream", "document": ["id": Int32(2)]]]]
            let media = try XCTUnwrap(TelegramVideo.from(message: message, chatID: 1))
            XCTAssertEqual(media.title, name); XCTAssertEqual(media.caption, "Synthetic caption")
            XCTAssertFalse(media.isAudio)
        }
        let audio: [String: Any] = ["id": Int64(1), "content": ["audio": ["title": "Synthetic title", "audio": ["id": Int32(2)]]]]
        XCTAssertNil(TelegramVideo.from(message: audio, chatID: 1))
        for name in ["Synthetic.flac", "Synthetic.mp3", "Synthetic.pdf", "Synthetic.jpg"] {
            let document: [String: Any] = ["id": Int64(1), "content": ["document": ["file_name": name, "document": ["id": Int32(2)]]]]
            XCTAssertNil(TelegramVideo.from(message: document, chatID: 1))
        }
    }
    func testHistoryWriteCannotReplaceRefreshedFileMetadata() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let db = LibraryDatabase(url: root.appendingPathComponent("library.sqlite"))
        let old = TelegramVideo(messageID: 7, chatID: 1, fileID: 9, title: "Synthetic", size: 200, mimeType: "video/mp4", duration: 100, localPath: "/synthetic/old", downloadedBytes: 200, isDownloaded: true)
        var fresh = old; fresh.fileName = "Refreshed.mkv"; fresh.remoteUniqueID = "synthetic-new-file"
        fresh.localPath = ""; fresh.downloadedBytes = 0; fresh.isDownloaded = false
        try await db.savePage(videos: [fresh], chatID: 1, index: CollectionIndex())
        try await db.save(progress: WatchProgress(videoID: old.id, position: 30, duration: 100), video: old)
        let result = try await db.snapshot()
        XCTAssertEqual(result.videos.first?.fileName, "Refreshed.mkv")
        XCTAssertEqual(result.videos.first?.remoteUniqueID, "synthetic-new-file")
        XCTAssertEqual(result.videos.first?.localPath, "")
        XCTAssertEqual(result.history[old.id]?.position, 30)
    }

    func testVersionOneDatabaseMigratesWithoutLosingMetadataOrHistory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("library.sqlite")
        let db = LibraryDatabase(url: url)
        let item = TelegramVideo(messageID: 7, chatID: 1, fileID: 9, title: "Synthetic.mkv", size: 200, mimeType: "video/mp4", duration: 100, localPath: "", downloadedBytes: 0, isDownloaded: false)
        try await db.save(collection: TelegramChat(id: 1, title: "Synthetic", type: "chatTypeSupergroup"), selectedByDefault: true)
        try await db.save(progress: WatchProgress(videoID: item.id, position: 30, duration: 100), video: item)
        // Simulate the actual previous schema: no paging table, user_version = 1.
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &connection), SQLITE_OK)
        defer { sqlite3_close(connection) }
        XCTAssertEqual(sqlite3_exec(connection, "DROP TABLE collection_indexes; PRAGMA user_version=1", nil, nil, nil), SQLITE_OK)
        let migrated = try await LibraryDatabase(url: url).snapshot()
        XCTAssertEqual(migrated.videos.map(\.id), [item.id])
        XCTAssertEqual(migrated.selected, [1])
        XCTAssertEqual(migrated.history[item.id]?.position, 30)
        XCTAssertTrue(migrated.indexes.isEmpty)
    }

    func testOldestOrderUsesDatesThenMessageIDs() {
        let a = TelegramVideo(messageID: 7, chatID: 1, fileID: 9, title: "Synthetic", size: 0, mimeType: "video/mp4", duration: 0, localPath: "", downloadedBytes: 0, isDownloaded: false, date: 200)
        var b = a; b.date = 100
        XCTAssertEqual(LibraryOrder.oldest.sort([a, b]).map(\.date), [100, 200])
        XCTAssertEqual(LibraryOrder.newest.sort([b, a]).map(\.date), [200, 100])
    }
}

final class SavedListMigrationTests: XCTestCase {
    func testVersionTwoUpgradeRetainsSelectionHistoryAndCursor() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("library.sqlite")
        let db = LibraryDatabase(url: url)
        let video = TelegramVideo(messageID: 7, chatID: 1, fileID: 9, title: "Synthetic", size: 0, mimeType: "video/mp4", duration: 120, localPath: "", downloadedBytes: 0, isDownloaded: false)
        try await db.save(collection: TelegramChat(id: 1, title: "Synthetic", type: "chatTypeSupergroup"), selectedByDefault: true)
        var index = CollectionIndex(); index.advance(filter: CollectionIndex.filters[0], from: 0, next: 42)
        try await db.savePage(videos: [video], chatID: 1, index: index)
        try await db.save(progress: WatchProgress(videoID: video.id, position: 30, duration: 120), video: video)
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &connection), SQLITE_OK)
        defer { sqlite3_close(connection) }
        XCTAssertEqual(sqlite3_exec(connection, "DROP TABLE saved_lists; PRAGMA user_version=2", nil, nil, nil), SQLITE_OK)
        let upgraded = LibraryDatabase(url: url)
        try await upgraded.setSaved(video, list: "Favorites", saved: true)
        let state = try await upgraded.snapshot()
        XCTAssertEqual(state.selected, [1])
        XCTAssertEqual(state.indexes[1], index)
        XCTAssertEqual(state.history[video.id]?.position, 30)
        XCTAssertEqual(state.savedLists["Favorites"], [video.id])
    }
}
