import Foundation

/// Receives only messages whose configured bot sender has already been authenticated.
struct NoticeHistory {
    private(set) var messages: [Int64: [String: Any]] = [:]
    private(set) var clearedThrough: Int64 = 0
    private var removedIDs: Set<Int64> = []
    private var deletedCampaigns: Set<String> = []
    static func marker(_ message: [String: Any], prefix: String) -> String? {
        guard let markup = message["reply_markup"] as? [String: Any], markup["@type"] as? String == "replyMarkupInlineKeyboard",
              let rows = markup["rows"] as? [[[String: Any]]] else { return nil }
        for button in rows.flatMap({ $0 }) {
            guard let type = button["type"] as? [String: Any], type["@type"] as? String == "inlineKeyboardButtonTypeCallback",
                  let data = type["data"] as? String, let raw = Data(base64Encoded: data), let value = String(data: raw, encoding: .utf8),
                  value.hasPrefix(prefix) else { continue }
            let suffix = String(value.dropFirst(prefix.count))
            if suffix.count == 32, suffix.allSatisfy({ "0123456789abcdef".contains($0) }) { return suffix }
        }
        return nil
    }
    mutating func ingest(_ message: [String: Any]) {
        guard let id = message["id"] as? Int64, id > 0 else { return }
        if Self.marker(message, prefix: "notice-clear:1:") != nil {
            clearedThrough = max(clearedThrough, id)
            messages = messages.filter { $0.key > clearedThrough }
        } else if let campaign = Self.marker(message, prefix: "notice-delete:1:") {
            deletedCampaigns.insert(campaign)
            messages = messages.filter { Self.marker($0.value, prefix: "notice:1:") != campaign }
        } else if id > clearedThrough, !removedIDs.contains(id), let campaign = Self.marker(message, prefix: "notice:1:"), !deletedCampaigns.contains(campaign) {
            messages[id] = message
        }
    }
    mutating func remove(_ ids: [Int64]) { for id in ids { removedIDs.insert(id); messages.removeValue(forKey: id) } }
    var ordered: [[String: Any]] { messages.sorted { $0.key > $1.key }.map(\.value) }
}
