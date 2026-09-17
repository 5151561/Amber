import Foundation
import Security

/// 极简 Keychain 存取（存 QQ 音乐登录 cookie 等敏感信息）
enum KeychainHelper {

    private static let service = "com.changlepan.Amber"

    static func set(_ value: String, for key: String) {
        delete(key)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: value.data(using: .utf8)!,
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func get(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        // `SecItemCopyMatching` 的第二个形参是 `UnsafeMutablePointer<CFTypeRef?>?`，
        // Security 框架整套都是 C 接口，没有安全替代。`&result` 那一下是 inout-to-pointer，
        // 指针指向上一行这个局部变量，调用同步返回、不留指针，所以标记只罩这一句。
        // 钥匙串这边**只加标注**，查询字典与取值语义一个字节不动。
        guard unsafe SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
