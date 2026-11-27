import Foundation
import Security

/// Small wrapper around generic-password Keychain items, for pairing secrets.
/// Items never sync (iCloud Keychain off) and, on iOS, never leave this device.
enum Keychain {
    private static let service = "Flick pairing"

    static func data(_ account: String) -> Data? {
        var query = base(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    static func string(_ account: String) -> String? { data(account).map { String(decoding: $0, as: UTF8.self) } }

    @discardableResult
    static func set(_ value: Data, _ account: String) -> Bool {
        delete(account)
        var item = base(account)
        item[kSecValueData as String] = value
        #if os(iOS)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        #endif
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func set(_ value: String, _ account: String) -> Bool { set(Data(value.utf8), account) }

    static func delete(_ account: String) {
        SecItemDelete(base(account) as CFDictionary)
    }

    private static func base(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: false]
    }
}
