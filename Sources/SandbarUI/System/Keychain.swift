import Foundation
import Security

package nonisolated enum Keychain {
    package enum Failure: Error, Equatable { case status(OSStatus) }

    private static let service = "com.k27dong.sandbar"

    package static func read(_ name: String) throws -> String? {
        var query = item(name)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var found: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &found)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let value = found as? Data else { throw Failure.status(status) }
        return String(decoding: value, as: UTF8.self)
    }

    package static func write(_ value: String, as name: String) throws {
        let value = Data(value.utf8)
        var status = SecItemUpdate(item(name) as CFDictionary, [kSecValueData: value] as CFDictionary)
        if status == errSecItemNotFound {
            var new = item(name)
            new[kSecValueData] = value
            status = SecItemAdd(new as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw Failure.status(status) }
    }

    package static func delete(_ name: String) throws {
        let status = SecItemDelete(item(name) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure.status(status) }
    }

    private static func item(_ name: String) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: name]
    }
}
