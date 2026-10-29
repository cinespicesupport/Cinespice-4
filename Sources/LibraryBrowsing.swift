import Foundation

/// Derived once on the database actor, instead of sorting on every artwork/progress update.
struct LibraryBrowsing: Sendable {
    var collections: [TelegramChat] = []
    var videos: [TelegramVideo] = []
    var continuing: [TelegramVideo] = []
    var watched: [TelegramVideo] = []
    var fileIDs: Set<Int32> = []

    init() {}
    init(snapshot: LibrarySnapshot) {
        collections = TelegramChat.ownerFirst(snapshot.collections.filter { snapshot.selected.contains($0.id) && $0.isCollection })
        let selected = Set(collections.map(\.id))
        videos = snapshot.videos.filter { selected.contains($0.chatID) && !$0.isAudio }
            .sorted { $0.date == $1.date ? $0.messageID > $1.messageID : $0.date > $1.date }
        updateHistory(snapshot.history)
        fileIDs = Set(snapshot.videos.map(\.fileID))
    }
    mutating func updateHistory(_ history: [String: WatchProgress]) {
        watched = videos.filter { history[$0.id] != nil }.sorted {
            let left = history[$0.id]?.updatedAt ?? .distantPast
            let right = history[$1.id]?.updatedAt ?? .distantPast
            return left == right ? $0.id < $1.id : left > right
        }
        continuing = watched.filter { history[$0.id]?.canResume == true }
    }

}

/// Coalesces progress events. Thumbnail events never invalidate the media library.
struct LibraryFileUpdates {
    private(set) var latest: [Int32: LocalFileStatus] = [:]
    private var pending: [Int32: LocalFileStatus] = [:]
    mutating func receive(_ status: LocalFileStatus, knownFiles: Set<Int32>) -> Bool {
        guard knownFiles.contains(status.id), latest[status.id] != status else { return false }
        let completed = status.complete && latest[status.id]?.complete != true
        latest[status.id] = status
        pending[status.id] = status
        return completed
    }
    var hasPending: Bool { !pending.isEmpty }
    mutating func drain() -> [Int32: LocalFileStatus] {
        let batch = pending; pending.removeAll(keepingCapacity: true); return batch
    }
}

struct DownloadRecord: Codable, Equatable {
    enum State: String, Codable {
        case preparing = "Preparing", downloading = "Downloading", downloaded = "Downloaded"
        case cancelled = "Cancelled", paused = "Paused", retry = "Retry download"
    }
    var state: State
    var error = ""
    static func reconciled(previous: State, complete: Bool, exists: Bool, active: Bool) -> State {
        if complete && exists { return .downloaded }
        if previous == .cancelled || previous == .paused { return previous }
        if active && (previous == .downloading || previous == .preparing) { return .downloading }
        return .retry
    }
}
