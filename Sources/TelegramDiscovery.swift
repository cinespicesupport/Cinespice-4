import Foundation

/// Discovers metadata only. No message or file-download operation belongs here.
actor TelegramDiscovery {
    static let batchSize = 30
    typealias Request = @Sendable ([String: Any]) async throws -> [String: Any]
    struct Page: Sendable { let chats: [TelegramChat]; let hasMore: Bool }
    private let request: Request
    private var limits = [0, 0]
    private var exhausted = [false, false]
    private var nextList = 0
    private let lists = ["chatListMain", "chatListArchive"]

    init(request: @escaping Request) { self.request = request }

    func next(cached: [TelegramChat], accountID: Int64?) async throws -> Page {
        if exhausted.allSatisfy({ $0 }) { return Page(chats: [], hasMore: false) }
        let list = exhausted[nextList] ? 1 - nextList : nextList
        let limit = limits[list] + Self.batchSize
        var end = false
        do { _ = try await request(["@type": "loadChats", "chat_list": ["@type": lists[list]], "limit": Self.batchSize]) }
        catch { if (error as NSError).code == 404 { end = true } else { throw error } }
        try Task.checkCancellation()
        let result = try await request(["@type": "getChats", "chat_list": ["@type": lists[list]], "limit": limit])
        let ids = result["chat_ids"] as? [Int64] ?? []
        let known = Dictionary(cached.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        // Revisit a prefix after app restoration without resolving known metadata again.
        let candidates = ids.filter { id in
            guard let chat = known[id], chat.isChannel != nil else { return true }
            return ["chatTypeSupergroup", "chatTypeBasicGroup"].contains(chat.type) && chat.isOwner == nil
        }
        let chats = try await resolve(Array(candidates.prefix(Self.batchSize)), accountID: accountID)
        limits[list] = limit
        // A short page isn't proof of exhaustion: TDLib may load fewer than requested.
        exhausted[list] = end && ids.count < limit && candidates.count <= Self.batchSize
        nextList = 1 - list
        return Page(chats: chats, hasMore: !exhausted.allSatisfy({ $0 }))
    }

    func search(_ text: String, accountID: Int64?, channelsOnly: Bool = true) async throws -> [TelegramChat] {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        var parameters: [String: Any] = ["@type": "searchChatsOnServer", "query": query, "limit": Self.batchSize]
        if channelsOnly { parameters["type_filter"] = ["@type": "searchChatTypeFilterChannel"] }
        let remote = try await request(parameters)
        try Task.checkCancellation()
        parameters["@type"] = "searchChats"
        let local = try await request(parameters)
        var seen = Set<Int64>()
        let ids = ((remote["chat_ids"] as? [Int64] ?? []) + (local["chat_ids"] as? [Int64] ?? [])).filter { seen.insert($0).inserted }
        // Telegram's unfiltered search mixes users, bots and collections in the
        // same result page. Filter while resolving instead of truncating the raw
        // IDs first, or the first 30 non-group results can hide real channels.
        return try await resolve(ids, accountID: accountID, collectionLimit: Self.batchSize)
    }

    private func resolve(_ ids: [Int64], accountID: Int64?, collectionLimit: Int? = nil) async throws -> [TelegramChat] {
        var chats: [TelegramChat] = []
        for id in ids {
            try Task.checkCancellation()
            let data = try await request(["@type": "getChat", "chat_id": id])
            let type = data["type"] as? [String: Any] ?? [:]
            var group: [String: Any]?
            if let id = type["supergroup_id"] as? Int64 {
                group = try await request(["@type": "getSupergroup", "supergroup_id": id])
            } else if let id = type["basic_group_id"] as? Int64 {
                group = try await request(["@type": "getBasicGroup", "basic_group_id": id])
            }
            if let chat = TelegramChat.from(data, group: group, accountID: accountID) {
                if collectionLimit == nil || chat.isCollection { chats.append(chat) }
                if let collectionLimit, chats.count >= collectionLimit { break }
            }
        }
        return TelegramChat.ownerFirst(chats)
    }
}
