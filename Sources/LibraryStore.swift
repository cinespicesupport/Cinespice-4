import Foundation
import Combine

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var snapshot = LibrarySnapshot()
    @Published private(set) var error = ""
    @Published private(set) var isReady = false
    private(set) var accountID: Int64?
    private(set) var thumbnails: ThumbnailCache?
    @Published private(set) var fileStates: [Int32: LocalFileStatus] = [:]
    private var database: LibraryDatabase?
    @Published private(set) var artworkGeneration = 0
    private var generation = UUID()
    private var mediaGeneration = UUID()
    var sessionID: UUID { generation }

    private var fileUpdates = LibraryFileUpdates()
    private var filePublishTask: Task<Void, Never>?
    var selectedCollections: [TelegramChat] { snapshot.browsing.collections }
    var videos: [TelegramVideo] { snapshot.browsing.videos }
    var continueWatching: [TelegramVideo] { snapshot.browsing.continuing }
    var watchedVideos: [TelegramVideo] { snapshot.browsing.watched }

    func activate(accountID: Int64) async throws {
        deactivate()
        self.accountID = accountID
        let session = generation
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Tevee/Library/\(accountID)", isDirectory: true)
        let cacheRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Tevee/Thumbnails/\(accountID)", isDirectory: true)
        let db = LibraryDatabase(url: root.appendingPathComponent("library.sqlite"))
        let loaded = try await db.snapshot()
        guard generation == session else { throw CancellationError() }
        database = db
        thumbnails = ThumbnailCache(directory: cacheRoot)
        snapshot = loaded
        isReady = true
    }

    func deactivate() {
        generation = UUID(); accountID = nil; database = nil; thumbnails = nil
        filePublishTask?.cancel(); filePublishTask = nil; fileUpdates = LibraryFileUpdates()
        fileStates = [:]; snapshot = LibrarySnapshot(); isReady = false; error = ""
    }

    private func update(_ work: @Sendable (LibraryDatabase) async throws -> Void) async -> Bool {
        guard let database else { error = "The library is not ready."; return false }
        let session = generation
        do {
            try await work(database)
            let loaded = try await database.snapshot()
            guard generation == session else { return false }
            if loaded.revision >= snapshot.revision { snapshot = loaded }
            return true
        } catch {
            if generation == session { self.error = error.localizedDescription }
            return false
        }
    }

    @discardableResult func ingest(_ videos: [TelegramVideo]) async -> Bool { await update { try await $0.save(videos: videos) } }
    @discardableResult func register(_ chat: TelegramChat, savedMessages: Bool = false) async -> Bool { await update { try await $0.save(collection: chat, selectedByDefault: savedMessages) } }
    @discardableResult func select(_ chat: TelegramChat, selected: Bool) async -> Bool {
        await update { db in
            try await db.save(collection: chat)
            try await db.select(collectionID: chat.id, selected: selected)
        }
    }
    @discardableResult func register(_ chats: [TelegramChat]) async -> Bool { await update { try await $0.save(collections: chats) } }
    func savePage(_ videos: [TelegramVideo], chatID: Int64, index: CollectionIndex) async -> Bool {
        await update { try await $0.savePage(videos: videos, chatID: chatID, index: index) }
    }
    @discardableResult func setSaved(_ video: TelegramVideo, list: String, saved: Bool) async -> Bool {
        await update { try await $0.setSaved(video, list: list, saved: saved) }
    }
    func display(_ video: TelegramVideo) -> TelegramVideo {
        guard let status = fileUpdates.latest[video.fileID] else { return video }
        var copy = video
        copy.size = status.size; copy.localPath = status.path
        copy.downloadedBytes = status.downloaded; copy.isDownloaded = status.complete
        return copy
    }
    func updateFile(_ file: [String: Any]) {
        guard let status = LocalFileStatus(file) else { return }
        let completed = fileUpdates.receive(status, knownFiles: snapshot.browsing.fileIDs)
        if completed {
            let session = generation, media = mediaGeneration
            Task {
                guard generation == session, mediaGeneration == media else { return }
                _ = await update { try await $0.saveCompletedFile(status) }
            }
        }
        guard fileUpdates.hasPending, filePublishTask == nil else { return }
        filePublishTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 200_000_000) } catch { return }
            guard let self else { return }
            let batch = self.fileUpdates.drain()
            self.filePublishTask = nil
            if !batch.isEmpty { self.fileStates.merge(batch) { _, latest in latest } }
        }
    }
    func record(_ video: TelegramVideo, position: Double, duration: Double, completed: Bool = false, updatedAt: Date = Date()) async {
        let video = display(video)
        let progress = WatchProgress(videoID: video.id, position: position, duration: duration, completed: completed, updatedAt: updatedAt)
        _ = await update { try await $0.save(progress: progress, video: video) }
    }
    @discardableResult func clearHistory(videoID: String? = nil) async -> Bool { await update { try await $0.clearHistory(videoID: videoID) } }
    func invalidateMediaCache() async -> Bool { mediaGeneration = UUID(); filePublishTask?.cancel(); filePublishTask = nil; fileUpdates = LibraryFileUpdates(); fileStates = [:]; return await update { try await $0.invalidateMediaCache() } }
    func clearThumbnails() async throws { try await thumbnails?.clear(); artworkGeneration += 1 }
    func thumbnailBytes() async throws -> Int { try await thumbnails?.bytes() ?? 0 }
    func report(_ message: String) { error = message }
}
