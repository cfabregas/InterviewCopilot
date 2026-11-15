import Foundation

/// API Key 存在应用数据目录下的 keys.json 里(明文，仅本用户可读写)。
/// 应用完全不访问系统钥匙串。
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
        return load()[account] != nil
    }

    static func get(_ account: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let value = load()[account], !value.isEmpty else { return nil }
        return value
    }

    /// 保存；传空字符串表示删除。返回是否成功。
    @discardableResult
    static func set(_ value: String, for account: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        var keys = load()
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        keys[account] = trimmed.isEmpty ? nil : trimmed
        return save(keys)
    }
}
