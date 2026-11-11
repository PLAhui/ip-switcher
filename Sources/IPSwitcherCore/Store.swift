import Foundation

public enum Store {
    public static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/IPSwitcher")
    }

    public static var fileURL: URL {
        directory.appendingPathComponent("profiles.json")
    }

    public static var snapshotURL: URL {
        directory.appendingPathComponent("last-snapshot.json")
    }

    public enum StoreError: Error, LocalizedError {
        case decodeFailed(String)
        case noProfiles
        case profileNotFound(String)
        public var errorDescription: String? {
            switch self {
            case .decodeFailed(let detail): return "profiles.json 解析失败：\(detail)"
            case .noProfiles: return "profiles.json 中没有任何配置"
            case .profileNotFound(let id): return "找不到要编辑的方案：\(id)"
            }
        }
    }

    private static func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
    }

    public static func bootstrap() throws {
        try ensureDirectory()
        guard !FileManager.default.fileExists(atPath: fileURL.path) else { return }

        if let bundled = Bundle.main.url(forResource: "profiles", withExtension: "json"),
           let data = try? Data(contentsOf: bundled) {
            try data.write(to: fileURL, options: .atomic)
            IPSLog.write("首次启动：从 App 内置资源导入 profiles.json")
        } else {
            let store = try PresetBuilder.buildDefault()
            try save(store)
            IPSLog.write("首次启动：按网卡生成 \(store.profiles.count) 套 IP 预设")
        }
    }

    public static func load() throws -> ProfileStore {
        let data = try Data(contentsOf: fileURL)
        do {
            return try JSONDecoder().decode(ProfileStore.self, from: data)
        } catch {
            throw StoreError.decodeFailed(error.localizedDescription)
        }
    }

    public static func save(_ store: ProfileStore) throws {
        try ensureDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(store)
        try data.write(to: fileURL, options: .atomic)
    }

    public static func backupCurrent() -> URL? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let target = directory.appendingPathComponent(
            "profiles.backup-\(formatter.string(from: Date())).json")
        try? FileManager.default.copyItem(at: fileURL, to: target)
        return target
    }

    @discardableResult
    public static func regeneratePresets() throws -> ProfileStore {
        try ensureDirectory()
        let store = try PresetBuilder.buildDefault()
        if let backup = backupCurrent() {
            IPSLog.write("重新导入前已备份：\(backup.lastPathComponent)")
        }
        try save(store)
        IPSLog.write("重新按网卡导入完成，共 \(store.profiles.count) 套 IP 预设")
        return store
    }

    public static func appendProfile(_ profile: Profile) throws {
        var store = try load()
        if let index = store.profiles.firstIndex(where: { $0.id == profile.id }) {
            store.profiles[index] = profile
        } else {
            store.profiles.append(profile)
        }
        try save(store)
    }

    /// 原地更新已有方案（ID 不变），供界面「编辑方案」使用。
    public static func updateProfile(_ profile: Profile) throws {
        var store = try load()
        guard let index = store.profiles.firstIndex(where: { $0.id == profile.id }) else {
            throw StoreError.profileNotFound(profile.id)
        }
        store.profiles[index] = profile
        try save(store)
    }

    public static func deleteProfile(id: String) throws {
        var store = try load()
        let before = store.profiles.count
        store.profiles.removeAll { $0.id == id }
        guard store.profiles.count < before else { return }
        if store.activeProfileID == id { store.activeProfileID = nil }
        try save(store)
    }

    public static func writeSnapshot(_ snapshot: ConfigSnapshot) throws {
        try ensureDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(snapshot).write(to: snapshotURL, options: .atomic)
    }

    public static func readSnapshot() throws -> ConfigSnapshot {
        let data = try Data(contentsOf: snapshotURL)
        return try JSONDecoder().decode(ConfigSnapshot.self, from: data)
    }

    public static func setActiveProfileID(_ id: String?) throws {
        var store = try load()
        store.activeProfileID = id
        try save(store)
    }
}
