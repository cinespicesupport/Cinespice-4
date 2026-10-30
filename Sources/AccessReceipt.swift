import Foundation

/// Shared wire format. Signature verification is supplied by the platform's P-256 implementation.
struct AccessReceipt: Decodable {
    let v: Int
    let uid: String
    let nonce: String
    let status: String
    let iat: Int64
    let exp: Int64
    let device: String?
    let revision: Int64?
    let paid: Bool?
    let missing: [Int]?
    let persistent: Bool?

    static func decode(_ token: String, account: String, nonce: String, now: Int64,
                       device expectedDevice: String? = nil, allowStored: Bool = false, verify: (Data, Data) -> Bool) throws -> AccessReceipt {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard token.utf8.count <= 2048, parts.count == 3, parts[0] == "CSP1",
              let payload = decode64(String(parts[1])), let signature = decode64(String(parts[2])),
              signature.count <= 72, verify(Data("CSP1.\(parts[1])".utf8), signature) else { throw InvalidReceipt() }
        let receipt = try JSONDecoder().decode(Self.self, from: payload)
        guard receipt.v == 1, receipt.uid == account, receipt.nonce == nonce,
              nonce.count == 32, nonce.allSatisfy({ "0123456789abcdef".contains($0) }),
              ["authorized", "unpaid", "not_started", "join_required", "unavailable", "revoked", "other_device"].contains(receipt.status),
              receipt.iat <= now + 60, receipt.exp > receipt.iat, receipt.exp - receipt.iat <= 86400 else { throw InvalidReceipt() }
        let storedGrant = allowStored && expectedDevice != nil && receipt.persistent == true && receipt.status == "authorized"
        guard storedGrant || (receipt.iat >= now - 86400 && receipt.exp > now) else { throw InvalidReceipt() }
        if let expectedDevice {
            guard expectedDevice.count == 24, expectedDevice.allSatisfy({ "0123456789abcdef".contains($0) }),
                  receipt.device == expectedDevice, let revision = receipt.revision, revision >= 0,
                  receipt.paid != nil, let missing = receipt.missing, missing.allSatisfy({ (0..<10).contains($0) }) else { throw InvalidReceipt() }
        }
        return receipt
    }
    private static func decode64(_ value: String) -> Data? {
        guard value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { return nil }
        let text = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        return Data(base64Encoded: text + String(repeating: "=", count: (4 - text.count % 4) % 4))
    }
    struct InvalidReceipt: Error { }
}
