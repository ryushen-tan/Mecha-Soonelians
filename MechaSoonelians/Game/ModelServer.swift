import Foundation
import Security

/// The 3D service that turns hiders' photos into 3D models with Tripo: the hosted server by
/// default, or a Mac running `npm run start:3d` (server/tripo.mjs). The token is that server's
/// TRIPO_PROXY_TOKEN, never the Tripo API key.
struct ModelServer: Equatable {
    var address: String
    var token: String

    var isConfigured: Bool { !address.trimmingCharacters(in: .whitespaces).isEmpty }

    private static let addressKey = "ghostModelServer"
    private static let tokenAccount = "ghostModelServerToken"

    /// The host's saved server. The address lives in UserDefaults and the token in the Keychain.
    /// Launching with `--model-server <address> --model-token <token>` (from Xcode or devicectl)
    /// saves those first, so the token never has to be typed or committed.
    static var saved: ModelServer {
        let arguments = ProcessInfo.processInfo.arguments
        if let i = arguments.firstIndex(of: "--model-server"), i + 1 < arguments.count {
            let token = arguments.firstIndex(of: "--model-token").flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
            ModelServer(address: arguments[i + 1], token: token ?? "").save()
        }
        // A saved empty address means the host chose flat cutouts.
        let address = UserDefaults.standard.string(forKey: addressKey) ?? HostedCharacterService.address
        return ModelServer(address: address, token: HostedCharacterService.token(for: address, saved: loadToken() ?? ""))
    }

    func save() {
        UserDefaults.standard.set(address, forKey: Self.addressKey)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: Self.tokenAccount]
        SecItemDelete(query as CFDictionary)
        guard !token.isEmpty else { return }
        var item = query
        item[kSecValueData as String] = Data(token.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }

    private static func loadToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: tokenAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
