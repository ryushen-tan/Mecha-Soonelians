import Foundation
import Security

// Membership tokens stay in the device keychain, never in preferences or share links.
enum SessionVault {
    private static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.mechasoonelians.Rally",
        kSecAttrAccount as String: "active-room"
    ]

    static func read() -> Membership? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(Membership.self, from: data)
    }

    static func save(_ membership: Membership) {
        guard let data = try? JSONEncoder().encode(membership) else { return }
        clear()
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }

    static func clear() { SecItemDelete(query as CFDictionary) }
}
