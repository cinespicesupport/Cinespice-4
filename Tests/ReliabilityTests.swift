import XCTest
@testable import TeveeStreaming

final class ReliabilityTests: XCTestCase {
    func testSeekTimeoutProtectsHistoryUntilSuccessfulRetry() {
        var recovery = PlaybackRecovery()
        let now = Date(timeIntervalSince1970: 100)
        recovery.begin(120, now: now)
        XCTAssertTrue(recovery.protectsProgress)
        XCTAssertEqual(recovery.issue(duration: 300), 120)
        XCTAssertNil(recovery.issue(duration: 300))
        XCTAssertEqual(recovery.poll(position: 4, now: now.addingTimeInterval(60)), .timedOut)
        XCTAssertEqual(recovery.failedTarget, 120)
        XCTAssertNil(recovery.target)
        XCTAssertTrue(recovery.protectsProgress)
        XCTAssertEqual(recovery.poll(position: 4, now: now.addingTimeInterval(61)), .waiting)
        recovery.begin(recovery.failedTarget!, now: now.addingTimeInterval(62))
        XCTAssertEqual(recovery.issue(duration: 300), 120)
        XCTAssertEqual(recovery.poll(position: 119, now: now.addingTimeInterval(63)), .reached)
        XCTAssertFalse(recovery.protectsProgress)
    }
    func testUnseekableResumeAndStartOverRemainProtected() {
        var recovery = PlaybackRecovery()
        let now = Date(timeIntervalSince1970: 100)
        recovery.begin(120, now: now)
        XCTAssertEqual(recovery.poll(position: 120, now: now), .waiting, "Don't acknowledge a seek that was never issued")
        XCTAssertEqual(recovery.poll(position: 0, now: now.addingTimeInterval(60)), .timedOut)
        recovery.begin(0, now: now.addingTimeInterval(61))
        XCTAssertTrue(recovery.protectsProgress)
        XCTAssertEqual(recovery.issue(duration: 300), 0)
        XCTAssertEqual(recovery.poll(position: 0), .reached)
        XCTAssertFalse(recovery.protectsProgress)
    }
    func testManualSeekReplacesPendingResumeAndClampsToDuration() {
        var recovery = PlaybackRecovery()
        recovery.begin(120); _ = recovery.issue(duration: 300)
        recovery.begin(600)
        XCTAssertEqual(recovery.issue(duration: 300), 300)
        XCTAssertEqual(recovery.poll(position: 300), .reached)
        XCTAssertNil(recovery.failedTarget)
        recovery.begin(600, resuming: true)
        XCTAssertEqual(recovery.issue(duration: 300), 295)
    }
    func testDownloadReconciliationPreservesActiveIntentAndCancellation() throws {
        XCTAssertEqual(DownloadRecord.reconciled(previous: .downloading, complete: false, exists: false, active: true), .downloading)
        XCTAssertEqual(DownloadRecord.reconciled(previous: .downloading, complete: false, exists: true, active: false), .retry)
        XCTAssertEqual(DownloadRecord.reconciled(previous: .downloaded, complete: true, exists: false, active: false), .retry)
        XCTAssertEqual(DownloadRecord.reconciled(previous: .cancelled, complete: false, exists: true, active: true), .cancelled)
        XCTAssertEqual(DownloadRecord.reconciled(previous: .retry, complete: false, exists: true, active: true), .retry, "Streaming must not become a full download")
        XCTAssertEqual(DownloadRecord.reconciled(previous: .preparing, complete: true, exists: true, active: false), .downloaded)
        let records = ["1:2": DownloadRecord(state: .retry, error: "Interrupted")]
        XCTAssertEqual(try JSONDecoder().decode([String: DownloadRecord].self, from: JSONEncoder().encode(records)), records)
    }
    func testPausedDownloadSurvivesRestartAndStreamingActivity() throws {
        let record = DownloadRecord(state: .paused)
        let restored = try JSONDecoder().decode(DownloadRecord.self, from: JSONEncoder().encode(record))
        XCTAssertEqual(restored.state, .paused)
        for active in [false, true] {
            XCTAssertEqual(DownloadRecord.reconciled(previous: restored.state, complete: false, exists: true, active: active), .paused)
            XCTAssertEqual(DownloadRecord.reconciled(previous: restored.state, complete: false, exists: false, active: active), .paused)
        }
        XCTAssertEqual(DownloadRecord.reconciled(previous: .paused, complete: true, exists: true, active: false), .downloaded)
        XCTAssertEqual(DownloadRecord.reconciled(previous: .paused, complete: true, exists: false, active: false), .paused)
    }

    func testPermanentDeletionCannotBeResurrectedByInflightHistory() throws {
        let url = Bundle.module.url(forResource: "notice-history", withExtension: "json", subdirectory: "Fixtures")!
        let messages = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [[String: Any]]
        var history = NoticeHistory()
        let message = messages[0], id = message["id"] as! Int64
        history.remove([id]); history.ingest(message)
        XCTAssertTrue(history.ordered.isEmpty)
        history.ingest(messages[1])
        XCTAssertEqual(history.ordered.count, 1)
    }
    func testCachedSnapshotRemainsCoherentAcrossProgressListsAndMetadataChanges() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let db = LibraryDatabase(url: root.appendingPathComponent("library.sqlite"))
        let item = TelegramVideo(messageID: 7, chatID: 1, fileID: 9, title: "Synthetic", size: 200, mimeType: "video/mp4", duration: 120, localPath: "", downloadedBytes: 0, isDownloaded: false)
        try await db.save(collection: TelegramChat(id: 1, title: "Synthetic", type: "chatTypeSupergroup"), selectedByDefault: true)
        try await db.save(videos: [item])
        let initial = try await db.snapshot()
        let time = Date(timeIntervalSince1970: 100)
        try await db.save(progress: WatchProgress(videoID: item.id, position: 30, duration: 120, updatedAt: time), video: item)
        let progress = try await db.snapshot()
        XCTAssertGreaterThan(progress.revision, initial.revision)
        XCTAssertEqual(progress.browsing.continuing.map(\.id), [item.id])
        XCTAssertEqual(progress.videos, initial.videos)
        try await db.save(progress: WatchProgress(videoID: item.id, position: 5, duration: 120, updatedAt: time.addingTimeInterval(-1)), video: item)
        let stale = try await db.snapshot()
        XCTAssertEqual(stale.history[item.id]?.position, 30)
        try await db.setSaved(item, list: "Favorites", saved: true)
        let saved = try await db.snapshot()
        XCTAssertEqual(saved.savedLists["Favorites"], [item.id])
        XCTAssertEqual(saved.history[item.id]?.position, 30)
        try await db.clearHistory()
        let cleared = try await db.snapshot()
        XCTAssertTrue(cleared.history.isEmpty)
        XCTAssertTrue(cleared.browsing.continuing.isEmpty)
        XCTAssertEqual(cleared.savedLists["Favorites"], [item.id])
        try await db.select(collectionID: 1, selected: false)
        let deselected = try await db.snapshot()
        XCTAssertTrue(deselected.browsing.videos.isEmpty)
        XCTAssertEqual(deselected.videos, [item])
    }
}
