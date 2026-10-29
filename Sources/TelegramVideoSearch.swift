import Foundation

/// Server search stays within selected sources, with bounded round-robin work.
actor TelegramVideoSearch {
    struct Job { let chatID: Int64; let filter: String; var cursor: Int64 = 0 }
    struct Page: Sendable { let videos: [TelegramVideo]; let hasMore: Bool }
    private var buffered: [TelegramVideo] = []
    private var jobs: [Job]
    private let query: String
    private let request: TelegramDiscovery.Request
    init(chatIDs: [Int64], query: String, request: @escaping TelegramDiscovery.Request) {
        self.query = query; self.request = request
        jobs = chatIDs.sorted().flatMap { id in CollectionIndex.filters.map { Job(chatID: id, filter: $0) } }
    }
    func next() async throws -> Page {
        // Commit each successful request separately; failed requests retain their cursor.
        for _ in 0..<min(4, jobs.count) {
            try Task.checkCancellation()
            let job = jobs[0]
            let data = try await request(["@type": "searchChatMessages", "chat_id": job.chatID,
                "query": query, "from_message_id": job.cursor, "offset": 0, "limit": CollectionIndex.pageLimit,
                "filter": ["@type": job.filter]])
            try Task.checkCancellation()
            buffered += (data["messages"] as? [[String: Any]] ?? []).compactMap { TelegramVideo.from(message: $0, chatID: job.chatID) }
            jobs.removeFirst()
            let next = data["next_from_message_id"] as? Int64 ?? 0
            if next != 0, next != job.cursor { jobs.append(Job(chatID: job.chatID, filter: job.filter, cursor: next)) }
        }
        let page = Page(videos: buffered, hasMore: !jobs.isEmpty)
        buffered.removeAll()
        return page
    }
}
