import Foundation
import Security

struct TelegramCredentials: Codable {
    let apiID: String
    let apiHash: String
}

/// API credentials and the TDLib database key never enter the library DB or logs.
enum SecureStore {
    private static func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "app.tevee", kSecAttrAccount as String: key]
    }
    static func read(_ key: String) throws -> Data? {
        var query = query(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw failure(status) }
        return data
    }
    static func save(_ data: Data, key: String) throws {
        let base = query(key)
        let changes: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(base as CFDictionary, changes as CFDictionary)
        if status == errSecItemNotFound {
            var add = base
            for (key, value) in changes { add[key] = value }
            let added = SecItemAdd(add as CFDictionary, nil)
            guard added == errSecSuccess else { throw failure(added) }
        } else if status != errSecSuccess { throw failure(status) }
    }
    static func remove(_ key: String) throws {
        let status = SecItemDelete(query(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw failure(status) }
    }
    static func databaseKey() throws -> Data {
        if let data = try read("tdlib_database_key") {
            guard data.count == 32 else { throw failure(errSecDecode) }
            return data
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { throw failure(status) }
        let data = Data(bytes)
        try save(data, key: "tdlib_database_key")
        return data
    }
    static func installationID() throws -> String {
        // Keychain items can outlive an uninstall. A marker in app preferences
        // identifies that case, while allowing existing installations to migrate.
        let markerKey = "access.installation.marker"
        let localMarker = UserDefaults.standard.string(forKey: markerKey)
        let secureMarker = try read(markerKey).flatMap { String(data: $0, encoding: .utf8) }
        if secureMarker != nil && localMarker != secureMarker {
            try remove("access.installation")
        }
        if localMarker == nil || localMarker != secureMarker {
            let marker = UUID().uuidString
            try save(Data(marker.utf8), key: markerKey)
            UserDefaults.standard.set(marker, forKey: markerKey)
        }
        if let data = try read("access.installation"), let value = String(data: data, encoding: .utf8), value.range(of: #"^[0-9a-f]{24}$"#, options: .regularExpression) != nil { return value }
        var bytes = [UInt8](repeating: 0, count: 12)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { throw failure(status) }
        let value = bytes.map { String(format: "%02x", $0) }.joined()
        try save(Data(value.utf8), key: "access.installation")
        return value
    }
    private static func failure(_ code: OSStatus) -> NSError {
        NSError(domain: NSOSStatusErrorDomain, code: Int(code), userInfo: [NSLocalizedDescriptionKey: "Secure storage is unavailable (\(code)). Unlock your iPhone and retry."])
    }
}
