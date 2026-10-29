import Foundation
import PluginAPI

/// 每个插件一个独立 `UserDefaults` suite，suite 名直接用 pluginID。
///
/// 不再拼 `<bundle-id>.plugin.` 前缀：id 本身已是反向域名且全局唯一，
/// 再拼一层只会得到难以对照的长文件名（§6.5）。
@MainActor
final class PluginStoreImpl: PluginStore {
    private let suiteName: String
    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init?(pluginID: String) {
        guard let defaults = UserDefaults(suiteName: pluginID) else { return nil }
        self.suiteName = pluginID
        self.defaults = defaults
    }

    func value<T: Codable>(_ type: T.Type, forKey: String) -> T? {
        guard let data = defaults.data(forKey: forKey) else { return nil }
        return try? decoder.decode(T.self, from: data)
    }

    func set<T: Codable>(_ value: T, forKey: String) {
        guard let data = try? encoder.encode(value) else { return }
        defaults.set(data, forKey: forKey)
    }

    /// 只清本插件的 suite，绝不触碰标准域或其他插件。
    func removeAll() {
        defaults.removePersistentDomain(forName: suiteName)
    }
}
