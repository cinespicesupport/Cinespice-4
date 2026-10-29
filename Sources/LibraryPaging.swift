import Foundation

/// Persisted independently for every selected collection. Each user action reads
/// at most 30 results per video/document filter; unrelated documents are discarded.
struct CollectionIndex: Codable, Equatable, Sendable {
    static let filters = ["searchMessagesFilterVideo", "searchMessagesFilterDocument"]
    static let pageLimit = 30
    var cursors: [String: Int64] = Dictionary(uniqueKeysWithValues: filters.map { ($0, 0) })
    var updatedAt: Date = Date()
    var hasMore: Bool { Self.filters.contains { cursors[$0] != nil } }

    mutating func advance(filter: String, from: Int64, next: Int64) {
        if next == 0 || next == from { cursors.removeValue(forKey: filter) }
        else { cursors[filter] = next }
        updatedAt = Date()
    }
}

enum LibraryOrder: String, CaseIterable {
    case latestRelease, earliestRelease, titleAscending, titleDescending, newest, oldest
    var title: String {
        switch self {
        case .latestRelease: return "Latest releases"
        case .earliestRelease: return "Earliest releases"
        case .titleAscending: return "Title A–Z"
        case .titleDescending: return "Title Z–A"
        case .newest: return "Recently added"
        case .oldest: return "Oldest uploads"
        }
    }
    func sort(_ videos: [TelegramVideo]) -> [TelegramVideo] {
        let years: [String: Int?] = (self == .latestRelease || self == .earliestRelease)
            ? Dictionary(videos.map { ($0.id, $0.filenameYear) }, uniquingKeysWith: { first, _ in first }) : [:]
        let titles = (self == .titleAscending || self == .titleDescending)
            ? Dictionary(videos.map { ($0.id, $0.displayTitle) }, uniquingKeysWith: { first, _ in first }) : [:]
        return videos.sorted {
            if self == .latestRelease || self == .earliestRelease {
                let a = years[$0.id] ?? nil, b = years[$1.id] ?? nil
                if a != b {
                    guard let a else { return false }
                    guard let b else { return true }
                    return self == .latestRelease ? a > b : a < b
                }
            }
            if self == .titleAscending || self == .titleDescending {
                let result = (titles[$0.id] ?? $0.title).localizedStandardCompare(titles[$1.id] ?? $1.title)
                if result != .orderedSame { return self == .titleAscending ? result == .orderedAscending : result == .orderedDescending }
            }
            if $0.date != $1.date { return self == .oldest ? $0.date < $1.date : $0.date > $1.date }
            if $0.chatID != $1.chatID { return $0.chatID < $1.chatID }
            return self == .oldest ? $0.messageID < $1.messageID : $0.messageID > $1.messageID
        }
    }
}

extension TelegramVideo {
    private static let yearExpression = try? NSRegularExpression(pattern: #"(?<![A-Za-z0-9])(?:18[89][0-9]|19[0-9]{2}|20[0-9]{2})(?![A-Za-z0-9])"#)
    /// A filename hint, never a verified catalogue release date. Reject multiple
    /// years and embedded digits (e.g. 12020p); never infer from upload time.
    var filenameYear: Int? {
        let name = fileName ?? title
        guard let regex = Self.yearExpression else { return nil }
        let matches = regex.matches(in: name, range: NSRange(name.startIndex..., in: name))
        let years = Set(matches.compactMap { match -> Int? in
            guard let range = Range(match.range, in: name) else { return nil }
            return Int(name[range])
        })
        guard years.count == 1 else { return nil }
        return years.first
    }
}
