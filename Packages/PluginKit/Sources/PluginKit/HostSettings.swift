import Foundation
import Observation

/// 基座自身持久化的**最小**配置：只有「哪些插件被启用」与三项应用级设置。
/// 插件配置一律在各自 `PluginStore` 里，新增插件不修改这里（§6.5）。
@MainActor
@Observable
public final class HostSettings {
    private enum Key {
        static let enabledPlugins = "host.enabledPlugins"
        static let showMenuBarIcon = "host.showMenuBarIcon"
        static let showSettingsOnLaunch = "host.showSettingsOnLaunch"
    }

    @ObservationIgnored private let defaults: UserDefaults

    public var enabledPluginIDs: Set<String> {
        didSet { defaults.set(Array(enabledPluginIDs), forKey: Key.enabledPlugins) }
    }

    /// 关闭后仍必须有其他途径打开设置窗口（再次启动应用），否则用户会把自己锁在外面（§6.9）。
    public var showMenuBarIcon: Bool {
        didSet { defaults.set(showMenuBarIcon, forKey: Key.showMenuBarIcon) }
    }

    public var showSettingsOnLaunch: Bool {
        didSet { defaults.set(showSettingsOnLaunch, forKey: Key.showSettingsOnLaunch) }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.array(forKey: Key.enabledPlugins) as? [String] ?? []
        enabledPluginIDs = Set(stored)
        // 默认显示菜单栏图标；`object(forKey:)` 为 nil 说明从未写过，取默认值而不是 false。
        showMenuBarIcon = defaults.object(forKey: Key.showMenuBarIcon) as? Bool ?? true
        showSettingsOnLaunch = defaults.object(forKey: Key.showSettingsOnLaunch) as? Bool ?? true
    }
}
