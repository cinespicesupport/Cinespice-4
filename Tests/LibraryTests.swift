import XCTest
@testable import TeveeStreaming

/// All identities, metadata and image bytes below are synthetic test fixtures.
final class LibraryDatabaseTests: XCTestCase {
    private func folder() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    private func video(_ chat: Int64 = 1) -> TelegramVideo {
        TelegramVideo(messageID: 7, chatID: chat, fileID: 9, title: "Synthetic \"title\"; ' video", size: 200, mimeType: "video/mp4", duration: 120, localPath: "/synthetic/cache", downloadedBytes: 200, isDownloaded: true)
    }

    func testMetadataSelectionAndHistorySurviveReopening() async throws {
        let directory = folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("library.sqlite")
        let first = LibraryDatabase(url: url)
        let item = video()
        try await first.save(collection: TelegramChat(id: 1, title: "Synthetic collection", type: "chatTypePrivate"), selectedByDefault: true)
        try await first.save(videos: [item])
        try await first.save(progress: WatchProgress(videoID: item.id, position: 32, duration: 120), video: item)
        let reopened = LibraryDatabase(url: url)
        let result = try await reopened.snapshot()
        XCTAssertEqual(result.videos, [item])
        XCTAssertEqual(result.selected, [1])
        XCTAssertEqual(result.history[item.id]?.position, 32)
        XCTAssertEqual(result.history[item.id]?.canResume, true)
    }

    func testRefreshPreservesDeselectedCollectionsAndWatchHistory() async throws {
        let directory = folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let db = LibraryDatabase(url: directory.appendingPathComponent("library.sqlite"))
        let item = video()
        let chat = TelegramChat(id: 1, title: "Synthetic", type: "chatTypePrivate")
        try await db.save(collection: chat, selectedByDefault: true)
        try await db.select(collectionID: 1, selected: false)
        try await db.save(collection: chat, selectedByDefault: true)
        try await db.save(progress: WatchProgress(videoID: item.id, position: 30, duration: 120), video: item)
        try await db.save(videos: [item])
        let result = try await db.snapshot()
        XCTAssertTrue(result.selected.isEmpty)
        XCTAssertEqual(result.history[item.id]?.position, 30)
    }

    func testCacheInvalidationKeepsLibraryAndHistory() async throws {
        let directory = folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let db = LibraryDatabase(url: directory.appendingPathComponent("library.sqlite"))
        let item = video()
        try await db.save(progress: WatchProgress(videoID: item.id, position: 30, duration: 120), video: item)
        try await db.invalidateMediaCache()
        let result = try await db.snapshot()
        XCTAssertEqual(result.videos.count, 1)
        XCTAssertFalse(result.videos[0].isDownloaded)
        XCTAssertEqual(result.videos[0].localPath, "")
        XCTAssertEqual(result.history[item.id]?.position, 30)
    }

    func testAccountDatabasesAndChatScopedHistoryAreIndependent() async throws {
        let directory = folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let first = LibraryDatabase(url: directory.appendingPathComponent("1/library.sqlite"))
        let second = LibraryDatabase(url: directory.appendingPathComponent("2/library.sqlite"))
        let a = video(1), b = video(2)
        try await first.save(progress: WatchProgress(videoID: a.id, position: 20, duration: 120), video: a)
        try await first.save(progress: WatchProgress(videoID: b.id, position: 40, duration: 120), video: b)
        try await first.clearHistory(videoID: a.id)
        let firstResult = try await first.snapshot()
        let secondResult = try await second.snapshot()
        XCTAssertNil(firstResult.history[a.id])
        XCTAssertEqual(firstResult.history[b.id]?.position, 40)
        XCTAssertTrue(secondResult.videos.isEmpty)
        XCTAssertTrue(secondResult.history.isEmpty)
    }

    func testInvalidDatabaseIsNotSilentlyOverwritten() async throws {
        let directory = folder(); defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("library.sqlite")
        let original = Data("synthetic damaged database".utf8)
        try original.write(to: url)
        do { _ = try await LibraryDatabase(url: url).snapshot(); XCTFail("Expected failure") } catch { }
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testDelayedOlderProgressCannotOverwriteNewerPosition() async throws {
        let directory = folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let db = LibraryDatabase(url: directory.appendingPathComponent("library.sqlite"))
        let item = video()
        let now = Date()
        try await db.save(progress: WatchProgress(videoID: item.id, position: 75, duration: 120, updatedAt: now), video: item)
        try await db.save(progress: WatchProgress(videoID: item.id, position: 20, duration: 120, updatedAt: now.addingTimeInterval(-5)), video: item)
        let result = try await db.snapshot()
        XCTAssertEqual(result.history[item.id]?.position, 75)
    }

    func testBatchCollectionRefreshKeepsSelectionAndAdvancesRevision() async throws {
        let directory = folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let db = LibraryDatabase(url: directory.appendingPathComponent("library.sqlite"))
        let chat = TelegramChat(id: 1, title: "Synthetic", type: "chatTypePrivate")
        try await db.save(collection: chat, selectedByDefault: true)
        let before = try await db.snapshot()
        try await db.save(collections: [TelegramChat(id: 1, title: "Renamed", type: chat.type), TelegramChat(id: 2, title: "Other", type: chat.type)])
        let result = try await db.snapshot()
        XCTAssertEqual(result.selected, [1])
        XCTAssertEqual(result.collections.count, 2)
        XCTAssertEqual(result.collections.first(where: { $0.id == 1 })?.title, "Renamed")
        XCTAssertGreaterThan(result.revision, before.revision)
    }

    func testThumbnailMetadataAndLocalStateRoundTrip() throws {
        let message: [String: Any] = ["id": Int64(7), "date": Int64(1234), "content": ["video": [
            "video": ["id": Int32(9), "size": Int64(200)], "duration": 120,
            "thumbnail": ["format": ["@type": "thumbnailFormatJpeg"], "file": ["id": Int32(10), "remote": ["id": "synthetic-remote", "unique_id": "synthetic-unique"]]],
            "minithumbnail": ["data": Data([1, 2, 3]).base64EncodedString()]
        ]]]
        let item = try XCTUnwrap(TelegramVideo.from(message: message, chatID: 1))
        XCTAssertEqual(item.thumbnailFileID, 10)
        XCTAssertEqual(item.thumbnailRemoteID, "synthetic-remote")
        XCTAssertEqual(item.thumbnailUniqueID, "synthetic-unique")
        XCTAssertEqual(item.minithumbnail, Data([1, 2, 3]))
        XCTAssertEqual(item.date, 1234)
        let reopened = try JSONDecoder().decode(TelegramVideo.self, from: JSONEncoder().encode(item))
        XCTAssertEqual(reopened, item)
        let updated = item.updating(file: ["id": Int32(9), "size": Int64(200), "local": ["path": "/synthetic/new", "downloaded_size": Int64(200), "is_downloading_completed": true]])
        XCTAssertTrue(updated.isDownloaded)
        XCTAssertEqual(updated.localPath, "/synthetic/new")
        XCTAssertEqual(updated.thumbnailFileID, 10)
    }

    func testProgressNormalizationAndCompletion() {
        XCTAssertEqual(WatchProgress(videoID: "1:7", position: .nan, duration: .infinity).position, 0)
        XCTAssertFalse(WatchProgress(videoID: "1:7", position: 4, duration: 100).canResume)
        XCTAssertTrue(WatchProgress(videoID: "1:7", position: 30, duration: 100).canResume)
        XCTAssertTrue(WatchProgress(videoID: "1:7", position: 96, duration: 100).completed)
        XCTAssertFalse(WatchProgress(videoID: "1:7", position: 96, duration: 100).canResume)
    }
}

final class ThumbnailCacheTests: XCTestCase {
    func testCacheRoundTripBudgetAndClearPreserveUnrelatedFiles() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = ThumbnailCache(directory: folder, budget: 8)
        try await cache.write(Data([1, 2, 3, 4, 5]), key: "1_2_3")
        let first = try await cache.read("1_2_3")
        XCTAssertEqual(first, Data([1, 2, 3, 4, 5]))
        try await cache.write(Data([6, 7, 8, 9, 10]), key: "1_2_4")
        let bytes = try await cache.bytes()
        XCTAssertLessThanOrEqual(bytes, 8)
        let unrelated = folder.appendingPathComponent("keep.txt")
        try Data([42]).write(to: unrelated)
        try await cache.clear()
        let emptyBytes = try await cache.bytes()
        XCTAssertEqual(emptyBytes, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }

    func testTraversalAndOversizeWritesAreRejected() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = ThumbnailCache(directory: folder, budget: 4)
        for key in ["../session", "/tmp/secret", "a/b", ""] {
            do { try await cache.write(Data([1]), key: key); XCTFail("Expected rejection") } catch { }
        }
        do { try await cache.write(Data(repeating: 0, count: 5), key: "1_2_3"); XCTFail("Expected rejection") } catch { }
    }
}

final class SavedListAndSortTests: XCTestCase {
    private func item(_ id: Int64, _ name: String, date: Int64 = 0) -> TelegramVideo {
        TelegramVideo(messageID: id, chatID: 1, fileID: Int32(id), title: name, size: 0, mimeType: "video/mp4", duration: 0, localPath: "", downloadedBytes: 0, isDownloaded: false, date: date)
    }
    func testMembershipSurvivesReopenAndRefreshWithoutChangingHistory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("library.sqlite")
        let db = LibraryDatabase(url: url), video = item(1, "Synthetic (2024).mkv")
        try await db.setSaved(video, list: "Favorites", saved: true)
        try await db.setSaved(video, list: "Watchlist", saved: true)
        try await db.setSaved(video, list: "Favorites", saved: true)
        var refreshed = video; refreshed.fileName = "Updated.mkv"
        try await db.save(videos: [refreshed])
        let reopened = LibraryDatabase(url: url)
        let state = try await reopened.snapshot()
        XCTAssertEqual(state.savedLists["Favorites"], [video.id])
        XCTAssertEqual(state.savedLists["Watchlist"], [video.id])
        XCTAssertEqual(state.videos.first?.fileName, "Updated.mkv")
        XCTAssertTrue(state.history.isEmpty)
        try await reopened.setSaved(video, list: "Favorites", saved: false)
        try await reopened.invalidateMediaCache()
        let cleared = try await reopened.snapshot()
        XCTAssertNil(cleared.savedLists["Favorites"])
        XCTAssertEqual(cleared.savedLists["Watchlist"], [video.id])
        let other = try await LibraryDatabase(url: root.appendingPathComponent("other.sqlite")).snapshot()
        XCTAssertTrue(other.savedLists.isEmpty)
    }
    func testCompletedDownloadSurvivesRestartAndCacheClearKeepsLists() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("library.sqlite")
        let db = LibraryDatabase(url: url), video = item(1, "Synthetic")
        try await db.setSaved(video, list: "Watchlist", saved: true)
        let status = try XCTUnwrap(LocalFileStatus(["id": Int32(1), "size": Int64(200), "local": ["path": "/synthetic/file.mkv", "downloaded_size": Int64(200), "is_downloading_completed": true]]))
        try await db.saveCompletedFile(status)
        let reopened = LibraryDatabase(url: url)
        let saved = try await reopened.snapshot()
        XCTAssertEqual(saved.videos.first?.localPath, "/synthetic/file.mkv")
        XCTAssertEqual(saved.videos.first?.isDownloaded, true)
        try await reopened.invalidateMediaCache()
        let cleared = try await reopened.snapshot()
        XCTAssertEqual(cleared.videos.first?.isDownloaded, false)
        XCTAssertEqual(cleared.savedLists["Watchlist"], [video.id])
    }
    func testReleaseYearRejectsAmbiguousAndEmbeddedNumbers() {
        XCTAssertEqual(item(1, "Film.2024.1080p.mkv").filenameYear, 2024)
        XCTAssertNil(item(1, "Film.12024p.mkv").filenameYear)
        XCTAssertNil(item(1, "Film.2020-2024.mkv").filenameYear)
        XCTAssertNil(item(1, "Film.S02E2024.mkv").filenameYear)
        XCTAssertNil(item(1, "Film.1080p.mkv", date: 1700000000).filenameYear)
        var video = item(1, "Caption mentions 2025")
        video.fileName = "Film.1997.mkv"
        XCTAssertEqual(video.filenameYear, 1997)
    }
    func testReleaseSortAlwaysPlacesUnknownLast() {
        let old = item(1, "Film.1999.mkv"), new = item(2, "Film.2024.mkv"), unknown = item(3, "Unknown", date: 9999)
        XCTAssertEqual(LibraryOrder.latestRelease.sort([unknown, old, new]).map(\.messageID), [2, 1, 3])
        XCTAssertEqual(LibraryOrder.earliestRelease.sort([unknown, new, old]).map(\.messageID), [1, 2, 3])
    }
    func testTitleSortAndDeterministicTies() {
        let a = item(1, "Alpha"), b = item(2, "Bravo"), a2 = item(3, "Alpha")
        XCTAssertEqual(LibraryOrder.titleAscending.sort([b, a]).map(\.messageID), [1, 2])
        XCTAssertEqual(LibraryOrder.titleDescending.sort([a, b]).map(\.messageID), [2, 1])
        XCTAssertEqual(LibraryOrder.titleAscending.sort([a, a2]).map(\.messageID), [3, 1])
    }
}

final class LibraryFileUpdateTests: XCTestCase {
    func testBrowsingUsesSelectedVideoCollectionsAndPreservesResumeOrdering() {
        var snapshot = LibrarySnapshot()
        snapshot.collections = [TelegramChat(id: 1, title: "Films", type: "chatTypeSupergroup"), TelegramChat(id: 2, title: "Other", type: "chatTypeSupergroup")]
        snapshot.selected = [1]
        let first = TelegramVideo(messageID: 1, chatID: 1, fileID: 1, title: "Film.mkv", size: 100, mimeType: "video/mp4", duration: 120, localPath: "", downloadedBytes: 0, isDownloaded: false, date: 10)
        let second = TelegramVideo(messageID: 2, chatID: 1, fileID: 2, title: "New.mkv", size: 100, mimeType: "video/mp4", duration: 120, localPath: "", downloadedBytes: 0, isDownloaded: false, date: 20)
        var hidden = first; hidden = TelegramVideo(messageID: 3, chatID: 2, fileID: 3, title: "Hidden", size: 100, mimeType: "video/mp4", duration: 120, localPath: "", downloadedBytes: 0, isDownloaded: false)
        snapshot.videos = [first, hidden, second]
        snapshot.history[first.id] = WatchProgress(videoID: first.id, position: 30, duration: 120)
        let browsing = LibraryBrowsing(snapshot: snapshot)
        XCTAssertEqual(browsing.videos.map(\.id), [second.id, first.id])
        XCTAssertEqual(browsing.continuing.map(\.id), [first.id])
        XCTAssertEqual(browsing.collections.map(\.id), [1])
        XCTAssertEqual(browsing.fileIDs, [1, 2, 3])
    }
    func testProgressCoalescesAndIgnoresArtworkAndDuplicates() throws {
        var updates = LibraryFileUpdates()
        func status(_ id: Int32, _ bytes: Int64, complete: Bool = false) throws -> LocalFileStatus {
            try XCTUnwrap(LocalFileStatus(["id": id, "size": Int64(1000), "local": ["downloaded_size": bytes, "is_downloading_completed": complete]]))
        }
        XCTAssertFalse(updates.receive(try status(99, 1000, complete: true), knownFiles: [1]))
        XCTAssertFalse(updates.hasPending)
        for bytes in 0..<1000 { XCTAssertFalse(updates.receive(try status(1, Int64(bytes)), knownFiles: [1])) }
        let batch = updates.drain()
        XCTAssertEqual(batch.count, 1)
        XCTAssertEqual(batch[1]?.downloaded, 999)
        XCTAssertFalse(updates.hasPending)
        XCTAssertTrue(updates.receive(try status(1, 1000, complete: true), knownFiles: [1]))
        _ = updates.drain()
        XCTAssertFalse(updates.receive(try status(1, 1000, complete: true), knownFiles: [1]))
        XCTAssertFalse(updates.hasPending)
        updates = LibraryFileUpdates()
        XCTAssertTrue(updates.latest.isEmpty)
    }
}
