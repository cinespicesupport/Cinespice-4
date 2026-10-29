import Foundation

struct TelegramVideo: Identifiable, Hashable, Sendable, Codable {
    // Telegram message IDs are scoped to a chat.
    var id: String { "\(chatID):\(messageID)" }
    let messageID: Int64
    let chatID: Int64
    let fileID: Int32
    let title: String
    var size: Int64
    let mimeType: String
    let duration: Int
    var localPath: String
    var downloadedBytes: Int64
    var isDownloaded: Bool
    var date: Int64 = 0
    var thumbnailFileID: Int32? = nil
    var minithumbnail: Data? = nil
    var fileName: String? = nil
    var caption: String? = nil
    var remoteUniqueID: String? = nil
    var thumbnailUniqueID: String? = nil
    var thumbnailRemoteID: String? = nil
    var mediaKind: String? = nil
    var isAudio: Bool { mediaKind == "audio" || mimeType.lowercased().hasPrefix("audio/") || Self.audioExtensions.contains(((fileName ?? title) as NSString).pathExtension.lowercased()) }
    static let audioExtensions: Set<String> = ["mp3", "m4a", "aac", "flac", "ogg", "oga", "opus", "wav", "aiff", "alac", "wma", "ac3", "dts", "mka", "ape", "aif", "aifc", "amr"]
    static let videoExtensions: Set<String> = ["mp4", "m4v", "mkv", "mov", "avi", "webm", "mpeg", "mpg", "ts", "m2ts", "wmv", "flv", "ogv", "vob", "3gp", "3g2", "mts", "m2v", "divx", "asf", "f4v", "ogm", "rm", "rmvb", "nut", "mxf", "hevc", "h265", "h264", "av1", "m2p", "mpv", "mpe", "mjpeg", "mjpg", "mk3d", "3gpp", "3gpp2", "y4m", "dv"]

    /// Presentation only: keep title/fileName untouched for persistence and export.
    var displayTitle: String {
        var value = (fileName ?? title).components(separatedBy: .newlines).first ?? ""
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let extensions = Self.videoExtensions.union(Self.audioExtensions).sorted().joined(separator: "|")
        value = value.replacingOccurrences(of: "(?i)\\.(" + extensions + ")(?:\\s+\\1)?$", with: "", options: .regularExpression)
        // Match this known source before replacing separators: underscores can
        // otherwise make a handle indistinguishable from the film name.
        value = value.replacingOccurrences(of: #"(?i)^\s*[\[({]?\s*(?:(?:tg|telegram)[\s_.:-]*)?@streamers[-_]?hub[\])}]?[\s_.:-]*"#, with: "", options: .regularExpression)
        value = value.replacingOccurrences(of: #"(?i)^\s*(?:tg|telegram)\s+@[a-z0-9_]+\s+"#, with: "", options: .regularExpression)
        value = value.replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: #"(?<=[\w)])\.(?=[\w(])"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "._-")))
        return value.isEmpty ? "Untitled video" : value
    }
    var formatLabel: String {
        let ext = ((fileName ?? title) as NSString).pathExtension
        return ext.isEmpty ? (isAudio ? "AUDIO" : "VIDEO") : String(ext.prefix(8)).uppercased()
    }
    var thumbnailKey: String {
        if let unique = thumbnailUniqueID, !unique.isEmpty, unique.utf8.count <= 80 {
            let hex = unique.utf8.map { String(format: "%02x", $0) }.joined()
            return "0_0_\(hex)"
        }
        return "\(chatID)_\(messageID)_\(thumbnailFileID ?? 0)"
    }

    func updating(file: [String: Any]) -> TelegramVideo {
        var copy = self
        let local = file["local"] as? [String: Any] ?? [:]
        copy.size = file["size"] as? Int64 ?? size
        copy.localPath = local["path"] as? String ?? ""
        copy.downloadedBytes = local["downloaded_size"] as? Int64 ?? 0
        copy.isDownloaded = local["is_downloading_completed"] as? Bool ?? false
        return copy
    }

    static func from(message: [String: Any], chatID: Int64) -> TelegramVideo? {
        guard let messageID = message["id"] as? Int64,
              let content = message["content"] as? [String: Any] else { return nil }
        let media: [String: Any]
        let file: [String: Any]
        let isVideo: Bool
        if let video = content["video"] as? [String: Any], let value = video["video"] as? [String: Any] {
            media = video; file = value; isVideo = true
        } else if let document = content["document"] as? [String: Any], let value = document["document"] as? [String: Any] {
            media = document; file = value; isVideo = false
        } else { return nil }
        let name = media["file_name"] as? String ?? ""
        let mime = media["mime_type"] as? String ?? (isVideo ? "video/mp4" : "application/octet-stream")
        guard isVideo || mime.lowercased().hasPrefix("video/") || Self.videoExtensions.contains((name as NSString).pathExtension.lowercased()),
              let fileID = file["id"] as? Int32 else { return nil }
        let local = file["local"] as? [String: Any] ?? [:]
        let caption = (content["caption"] as? [String: Any])?["text"] as? String ?? ""
        let thumbnail = (media["thumbnail"] ?? media["album_cover_thumbnail"]) as? [String: Any]
        let format = (thumbnail?["format"] as? [String: Any])?["@type"] as? String ?? ""
        let thumbnailID = ["thumbnailFormatJpeg", "thumbnailFormatPng"].contains(format) ? (thumbnail?["file"] as? [String: Any])?["id"] as? Int32 : nil
        let miniEncoded = ((media["minithumbnail"] ?? media["album_cover_minithumbnail"]) as? [String: Any])?["data"] as? String ?? ""
        let mini = miniEncoded.utf8.count <= 64 * 1024 ? Data(base64Encoded: miniEncoded) : nil
        return TelegramVideo(messageID: messageID, chatID: chatID, fileID: fileID,
            title: !name.isEmpty ? name : (!caption.isEmpty ? String(caption.prefix(160)) : (media["title"] as? String ?? "Video")),
            size: file["size"] as? Int64 ?? 0, mimeType: mime,
            duration: media["duration"] as? Int ?? 0, localPath: local["path"] as? String ?? "",
            downloadedBytes: local["downloaded_size"] as? Int64 ?? 0,
            isDownloaded: local["is_downloading_completed"] as? Bool ?? false,
            date: message["date"] as? Int64 ?? 0, thumbnailFileID: thumbnailID, minithumbnail: mini,
            fileName: name.isEmpty ? nil : name, caption: caption.isEmpty ? nil : caption,
            remoteUniqueID: (file["remote"] as? [String: Any])?["unique_id"] as? String,
            thumbnailUniqueID: (((thumbnail?["file"] as? [String: Any])?["remote"] as? [String: Any])?["unique_id"] as? String),
            thumbnailRemoteID: (((thumbnail?["file"] as? [String: Any])?["remote"] as? [String: Any])?["id"] as? String),
            mediaKind: content["audio"] != nil ? "audio" : (mime.lowercased().hasPrefix("audio/") || Self.audioExtensions.contains((name as NSString).pathExtension.lowercased()) ? "audio" : "video"))
    }
}

struct TelegramChat: Identifiable, Hashable, Codable, Sendable {
    let id: Int64
    let title: String
    let type: String
    var isOwner: Bool? = nil
    var isChannel: Bool? = nil
    var telegramDate: Int64? = nil
    var usernames: [String]? = nil

    func matches(_ query: String) -> Bool {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let username = text.hasPrefix("@") ? String(text.dropFirst()) : text
        return text.isEmpty || title.localizedCaseInsensitiveContains(text) || (usernames?.contains(where: { $0.localizedCaseInsensitiveContains(username) }) == true)
    }

    static func from(_ data: [String: Any], group: [String: Any]? = nil, accountID: Int64? = nil) -> TelegramChat? {
        guard let id = data["id"] as? Int64 else { return nil }
        let type = data["type"] as? [String: Any] ?? [:]
        let channel = type["is_channel"] as? Bool ?? false
        return TelegramChat(id: id, title: id == accountID ? "Saved Messages" : (data["title"] as? String ?? "Untitled chat"),
            type: type["@type"] as? String ?? "chat", isOwner: group.map { ($0["status"] as? [String: Any])?["@type"] as? String == "chatMemberStatusCreator" },
            isChannel: channel, telegramDate: group?["date"] as? Int64, usernames: (group?["usernames"] as? [String: Any])?["active_usernames"] as? [String])
    }
    var isCollection: Bool { type == "chatTypeSupergroup" || type == "chatTypeBasicGroup" }

    static func ownerFirst(_ chats: [TelegramChat]) -> [TelegramChat] {
        chats.sorted {
            let lhs = $0.isOwner == true && $0.isChannel == true
            let rhs = $1.isOwner == true && $1.isChannel == true
            if lhs != rhs { return lhs }
            if lhs, $0.telegramDate != $1.telegramDate { return ($0.telegramDate ?? .max) < ($1.telegramDate ?? .max) }
            let order = $0.title.localizedCaseInsensitiveCompare($1.title)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }
}

struct WatchProgress: Codable, Equatable, Sendable {
    let videoID: String
    let position: Double
    let duration: Double
    let updatedAt: Date
    let completed: Bool

    init(videoID: String, position: Double, duration: Double, completed: Bool = false, updatedAt: Date = Date()) {
        self.videoID = videoID
        self.position = position.isFinite ? max(0, position) : 0
        self.duration = duration.isFinite ? max(0, duration) : 0
        self.completed = completed || (self.duration > 0 && self.position / self.duration >= 0.95)
        self.updatedAt = updatedAt
    }
    var canResume: Bool { !completed && position >= 5 }
    var fraction: Double { duration > 0 ? min(1, position / duration) : 0 }
}

struct LibrarySnapshot: Sendable {
    var browsing = LibraryBrowsing()
    var savedLists: [String: Set<String>] = [:]
    var revision: Int = 0
    var videos: [TelegramVideo] = []
    var collections: [TelegramChat] = []
    var selected: Set<Int64> = []
    var history: [String: WatchProgress] = [:]
    var indexes: [Int64: CollectionIndex] = [:]
}

struct LocalFileStatus: Sendable, Equatable {
    let id: Int32
    let size: Int64
    let path: String
    let downloaded: Int64
    let complete: Bool
    init?(_ file: [String: Any]) {
        guard let id = file["id"] as? Int32, let local = file["local"] as? [String: Any] else { return nil }
        self.id = id; size = file["size"] as? Int64 ?? 0
        path = local["path"] as? String ?? ""
        downloaded = local["downloaded_size"] as? Int64 ?? 0
        complete = local["is_downloading_completed"] as? Bool ?? false
    }
}
