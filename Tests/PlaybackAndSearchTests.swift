import XCTest
@testable import TeveeStreaming

final class PlaybackActivityTests: XCTestCase {
    func testBufferingFlagDoesNotCoverAdvancingPlayback() {
        var activity = PlaybackActivity()
        let start = Date(timeIntervalSince1970: 0)
        for tick in 0..<20 {
            XCTAssertFalse(activity.stalled(time: Double(tick) / 2, waiting: true, paused: false, now: start.addingTimeInterval(Double(tick) / 2)))
        }
    }
    func testStallDebouncePauseAndRecovery() {
        var activity = PlaybackActivity()
        let now = Date(timeIntervalSince1970: 0)
        XCTAssertFalse(activity.stalled(time: 0, waiting: true, paused: false, now: now))
        XCTAssertFalse(activity.stalled(time: 0, waiting: true, paused: false, now: now.addingTimeInterval(1)))
        XCTAssertTrue(activity.stalled(time: 0, waiting: true, paused: false, now: now.addingTimeInterval(2)))
        XCTAssertFalse(activity.stalled(time: 1, waiting: true, paused: false, now: now.addingTimeInterval(3)))
        XCTAssertFalse(activity.stalled(time: 1, waiting: true, paused: true, now: now.addingTimeInterval(30)))
        XCTAssertFalse(activity.stalled(time: 1, waiting: true, paused: false, now: now.addingTimeInterval(31)))
    }
}

private actor VideoSearchFixture {
    var calls: [[String: Any]] = []
    var failOnce: Bool
    init(failOnce: Bool = false) { self.failOnce = failOnce }
    func request(_ value: [String: Any]) throws -> [String: Any] {
        calls.append(value)
        if failOnce && calls.count == 2 { failOnce = false; throw URLError(.networkConnectionLost) }
        let chat = value["chat_id"] as! Int64
        let from = value["from_message_id"] as! Int64
        let filter = (value["filter"] as! [String: String])["@type"]!
        // A short non-video document page still has a valid cursor.
        if filter == "searchMessagesFilterDocument" && from == 0 {
            return ["messages": [["id": Int64(88), "content": ["document": ["file_name": "notes.pdf", "document": ["id": Int32(6)]]]]], "next_from_message_id": Int64(70)]
        }
        let id: Int64 = filter == "searchMessagesFilterVideo" ? 90 : 60
        return ["messages": [["id": id, "content": ["document": ["file_name": "Unindexed-\(chat).mkv", "mime_type": "video/x-matroska", "document": ["id": Int32(chat)]]]]], "next_from_message_id": Int64(0)]
    }
    func requests() -> [[String: Any]] { calls }
}

final class ScopedVideoSearchTests: XCTestCase {
    func testUnindexedVideosAndSparseDocumentPagesAreSearchedOnlyInSelectedSources() async throws {
        let fixture = VideoSearchFixture()
        let search = TelegramVideoSearch(chatIDs: [11, 22, 33], query: "Unindexed") { try await fixture.request($0) }
        var found: [TelegramVideo] = []
        var pages = 0
        while true {
            let before = await fixture.requests().count
            let page = try await search.next()
            let after = await fixture.requests().count
            XCTAssertLessThanOrEqual(after - before, 4)
            found += page.videos; pages += 1
            if !page.hasMore { break }
            XCTAssertLessThan(pages, 10)
        }
        XCTAssertEqual(Set(found.map(\.chatID)), [11, 22, 33])
        XCTAssertEqual(found.count, 6)
        XCTAssertTrue(found.allSatisfy { $0.fileName?.hasSuffix(".mkv") == true })
        for request in await fixture.requests() {
            XCTAssertEqual(request["@type"] as? String, "searchChatMessages")
            XCTAssertEqual(request["query"] as? String, "Unindexed")
            XCTAssertEqual(request["limit"] as? Int, 30)
            XCTAssertTrue([Int64(11), 22, 33].contains(request["chat_id"] as! Int64))
        }
    }
    func testRetryKeepsAlreadyFetchedResultsAndFailedCursor() async throws {
        let fixture = VideoSearchFixture(failOnce: true)
        let search = TelegramVideoSearch(chatIDs: [11], query: "Unindexed") { try await fixture.request($0) }
        do { _ = try await search.next(); XCTFail("Expected failure") } catch { }
        let retry = try await search.next()
        XCTAssertEqual(retry.videos.map(\.messageID), [90])
        XCTAssertTrue(retry.hasMore)
        let last = try await search.next()
        XCTAssertEqual(last.videos.map(\.messageID), [60])
        XCTAssertFalse(last.hasMore)
    }
    func testLegacyAudioCursorDoesNotKeepVideoPaginationAlive() throws {
        let data = Data(#"{"cursors":{"searchMessagesFilterAudio":22},"updatedAt":0}"#.utf8)
        let index = try JSONDecoder().decode(CollectionIndex.self, from: data)
        XCTAssertFalse(index.hasMore)
    }
    func testGroupsAreCollectionsAndPrivateChatsAreNot() {
        XCTAssertTrue(TelegramChat(id: 1, title: "Group", type: "chatTypeBasicGroup").isCollection)
        XCTAssertTrue(TelegramChat(id: 2, title: "Channel", type: "chatTypeSupergroup").isCollection)
        XCTAssertFalse(TelegramChat(id: 3, title: "Chat", type: "chatTypePrivate").isCollection)
    }
}

final class SubtitleAppearanceTests: XCTestCase {
    func testNumericSizesClampAndMigrateTheOldRelativePresets() {
        XCTAssertEqual(SubtitleSize(1).points, 6)
        XCTAssertEqual(SubtitleSize(99).points, 18)
        XCTAssertEqual(SubtitleSize.restored(0).points, 12)
        XCTAssertEqual(SubtitleSize.restored(-1).points, 12)
        XCTAssertEqual(SubtitleSize.restored(18, legacy: 20).points, 18)
        XCTAssertEqual([20,18,16,12,6].map { SubtitleSize.restored(0, legacy: $0).points }, [6,8,12,15,18])
        for value in 6...18 { XCTAssertEqual(SubtitleSize.restored(value).points, value) }
    }
    func testSizeCalibrationUsesVisiblePictureHeightAndRejectsMissingGeometry() {
        XCTAssertEqual(SubtitleSize(12).rendererDivisor(pictureHeight: 240), 20)
        XCTAssertEqual(SubtitleSize(6).rendererDivisor(pictureHeight: 240), 40)
        XCTAssertEqual(SubtitleSize(18).rendererDivisor(pictureHeight: 240), 13)
        XCTAssertEqual(SubtitleSize(12).rendererDivisor(pictureHeight: 480), 40)
        XCTAssertNil(SubtitleSize(12).rendererDivisor(pictureHeight: 0))
        XCTAssertNil(SubtitleSize(12).rendererDivisor(pictureHeight: .infinity))
        XCTAssertNil(SubtitleSize(12).rendererDivisor(pictureHeight: .nan))
    }
}
