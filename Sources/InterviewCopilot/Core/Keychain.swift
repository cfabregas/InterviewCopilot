import Foundation
import Security

/// API Key 存在应用数据目录下的 keys.json 里(明文，仅本用户可读写)。
/// 之前存在系统钥匙串，但没有签名证书时每次重新打包都要重新授权读取，所以改成文件。
enum KeyStore {
    private static let file = AppPaths.root.appendingPathComponent("keys.json")
    private static let lock = NSLock()

    private static func load() -> [String: String] {
        guard let data = try? Data(contentsOf: file),
              let keys = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return keys
    }

    private static func save(_ keys: [String: String]) -> Bool {
        guard let data = try? JSONEncoder().encode(keys) else { return false }
        do {
            try data.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            return true
        } catch {
            return false
        }
    }

    static func has(_ account: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return load()[account] != nil || LegacyKeychain.has(account)
    }

    static func get(_ account: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        var keys = load()
        if let value = keys[account], !value.isEmpty { return value }
        // 之前存在钥匙串里的密钥：读一次(系统会最后问一次授权)，搬到文件里
        guard let old = LegacyKeychain.get(account) else { return nil }
        keys[account] = old
        if save(keys) {
            LegacyKeychain.delete(account)
            Log.write("已把 \(account) 的密钥从钥匙串迁移到应用数据目录")
        }
        return old
    }

    /// 保存；传空字符串表示删除。返回是否成功。
    @discardableResult
    static func set(_ value: String, for account: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        LegacyKeychain.delete(account)
        var keys = load()
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        keys[account] = trimmed.isEmpty ? nil : trimmed
        return save(keys)
    }
}

/// 旧的钥匙串存储，只用于把已有密钥迁移出来
private enum LegacyKeychain {
    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "local.interviewcopilot.app",
         kSecAttrAccount as String: account]
    }

    static func has(_ account: String) -> Bool {
        var q = query(account)
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(q as CFDictionary, nil) == errSecSuccess
    }

    static func get(_ account: String) -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8), !value.isEmpty else { return nil }
        return value
    }

    static func delete(_ account: String) {
        SecItemDelete(query(account) as CFDictionary)
    }
}
