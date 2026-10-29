import Foundation
import CryptoKit

struct AccessConfiguration: Decodable {
    struct Channel: Decodable, Identifiable {
        let title: String
        let url: String
        var id: String { url }
    }
    let botUsername: String
    let botUserID: String
    let publicKey: String
    let contactURL: String
    let channels: [Channel]

    static func load() -> Self? {
        guard let url = Bundle.main.url(forResource: "CinespiceAccess", withExtension: "json"),
              let data = try? Data(contentsOf: url), let config = try? JSONDecoder().decode(Self.self, from: data),
              Int64(config.botUserID).map({ $0 > 0 }) == true,
              config.botUsername.range(of: #"^[A-Za-z0-9_]{5,32}$"#, options: .regularExpression) != nil,
              config.botUsername.lowercased().hasSuffix("bot"), config.channels.count <= 10,
              safeLink(config.contactURL) != nil,
              config.channels.allSatisfy({ !$0.title.isEmpty && safeLink($0.url) != nil }),
              let key = Data(base64Encoded: config.publicKey), (try? P256.Signing.PublicKey(derRepresentation: key)) != nil else { return nil }
        return config
    }
    static func safeLink(_ text: String) -> URL? {
        guard let url = URL(string: text), url.scheme == "https", url.host == "t.me", url.user == nil,
              url.password == nil, url.port == nil, url.query == nil, url.fragment == nil, url.path.count > 1 else { return nil }
        return url
    }
    var fingerprint: String {
        let value = ([botUserID, botUsername.lowercased(), publicKey, contactURL] + channels.map { $0.url }).joined(separator: "\n")
        return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    func receipt(_ text: String, account: Int64, nonce: String, device: String? = nil) throws -> AccessReceipt {
        let key = try P256.Signing.PublicKey(derRepresentation: Data(base64Encoded: publicKey) ?? Data())
        return try AccessReceipt.decode(text, account: String(account), nonce: nonce, now: Int64(Date().timeIntervalSince1970), device: device) { data, signature in
            guard let signature = try? P256.Signing.ECDSASignature(derRepresentation: signature) else { return false }
            return key.isValidSignature(signature, for: data)
        }
    }
}

struct AccessSnapshot: Codable {
    let token: String
    let nonce: String
    let device: String
    let revision: Int64

    static func eventRevision(_ message: [String: Any]) -> Int64? {
        guard let markup = message["reply_markup"] as? [String: Any], let rows = markup["rows"] as? [[[String: Any]]] else { return nil }
        for button in rows.flatMap({ $0 }) {
            guard let type = button["type"] as? [String: Any], type["@type"] as? String == "inlineKeyboardButtonTypeCallback",
                  let encoded = type["data"] as? String, let data = Data(base64Encoded: encoded), let text = String(data: data, encoding: .utf8),
                  text.hasPrefix("access:1:"), let revision = Int64(text.dropFirst(9)), revision > 0 else { continue }
            return revision
        }
        return nil
    }
}
