import Foundation

/// 协议而非具体类：实现（`PluginStoreImpl`）属于 `PluginKit`，`PluginAPI` 保持零实现。
/// 底层为独立 `UserDefaults(suiteName: pluginID)`。
@MainActor
public protocol PluginStore: AnyObject {
    func value<T: Codable>(_ type: T.Type, forKey: String) -> T?
    func set<T: Codable>(_ value: T, forKey: String)
    /// 「重置此插件」。
    func removeAll()
}
