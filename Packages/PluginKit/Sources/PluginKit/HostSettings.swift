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
        static let allowThirdPartyPlugins = "host.allowThirdPartyPlugins"
        static let marketplaceSources = "host.marketplaceSources"
        // 旧版单市场配置，仅用于迁移
        static let legacyMarketplaceURL = "host.marketplaceURL"
        static let legacyMarketplacePublicKey = "host.marketplacePublicKey"
        static let autoCheckPluginUpdates = "host.autoCheckPluginUpdates"
        static let autoInstallPluginUpdates = "host.autoInstallPluginUpdates"
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

    /// 允许安装/加载非同一 Team 签名的插件。默认关闭：
    /// 打开后基座必须关闭 Library Validation，安全基线下降（见外部插件设计文档 §4.4）。
    public var allowThirdPartyPlugins: Bool {
        didSet { defaults.set(allowThirdPartyPlugins, forKey: Key.allowThirdPartyPlugins) }
    }

    /// 插件市场来源列表。官方来源来自 Info.plist，用户可追加第三方市场。
    public var marketplaceSources: [MarketplaceSource] {
        didSet {
            if let data = try? JSONEncoder().encode(marketplaceSources) {
                defaults.set(data, forKey: Key.marketplaceSources)
            }
        }
    }

    public var autoCheckPluginUpdates: Bool {
        didSet { defaults.set(autoCheckPluginUpdates, forKey: Key.autoCheckPluginUpdates) }
    }

    /// 自动安装更新。默认关闭：更新可能改变能力声明，导致插件需要重新授权。
    public var autoInstallPluginUpdates: Bool {
        didSet { defaults.set(autoInstallPluginUpdates, forKey: Key.autoInstallPluginUpdates) }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.array(forKey: Key.enabledPlugins) as? [String] ?? []
        enabledPluginIDs = Set(stored)
        // 默认显示菜单栏图标；`object(forKey:)` 为 nil 说明从未写过，取默认值而不是 false。
        showMenuBarIcon = defaults.object(forKey: Key.showMenuBarIcon) as? Bool ?? true
        showSettingsOnLaunch = defaults.object(forKey: Key.showSettingsOnLaunch) as? Bool ?? true
        allowThirdPartyPlugins = defaults.object(forKey: Key.allowThirdPartyPlugins) as? Bool ?? false

        if let data = defaults.data(forKey: Key.marketplaceSources),
           let stored = try? JSONDecoder().decode([MarketplaceSource].self, from: data) {
            marketplaceSources = stored
        } else {
            // 官方市场始终来自 Info.plist；旧的单市场覆盖作为附加来源保留，避免丢配置。
            var initial = [MarketplaceSource.bundledOfficial()].compactMap { $0 }
            let legacyURL = (defaults.string(forKey: Key.legacyMarketplaceURL) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !legacyURL.isEmpty, legacyURL != initial.first?.url {
                initial.append(
                    MarketplaceSource(
                        id: "legacy",
                        name: "自定义市场",
                        url: legacyURL,
                        publicKey: defaults.string(forKey: Key.legacyMarketplacePublicKey) ?? ""
                    )
                )
            }
            marketplaceSources = initial
        }
        autoCheckPluginUpdates = defaults.object(forKey: Key.autoCheckPluginUpdates) as? Bool ?? true
        autoInstallPluginUpdates = defaults.object(forKey: Key.autoInstallPluginUpdates) as? Bool ?? false
    }
}
