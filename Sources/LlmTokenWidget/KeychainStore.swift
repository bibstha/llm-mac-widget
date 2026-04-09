import Foundation
import Security

enum KeychainStore {
    private static let service = "com.zai-token-widget.apikey"
    private static let account = "ZAI_API_KEY"

    static func load() -> String? {
        var item: CFTypeRef?
        let status = SecItemCopyMatching(
            [
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: service,
                kSecAttrAccount: account,
                kSecReturnData: true,
                kSecMatchLimit: kSecMatchLimitOne
            ] as CFDictionary,
            &item
        )
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ value: String) -> Bool {
        let data = Data(value.utf8)
        SecItemDelete([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ] as CFDictionary)
        let status = SecItemAdd(
            [
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: service,
                kSecAttrAccount: account,
                kSecValueData: data,
                kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock
            ] as CFDictionary,
            nil
        )
        return status == errSecSuccess
    }

    static func delete() {
        SecItemDelete([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ] as CFDictionary)
    }
}
