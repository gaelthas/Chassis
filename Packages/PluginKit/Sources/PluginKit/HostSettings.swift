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
        static let marketplaceURL = "host.marketplaceURL"
        static let marketplacePublicKey = "host.marketplacePublicKey"
        static let autoCheckPluginUpdates = "host.autoCheckPluginUpdates"
        static let autoInstallPluginUpdates = "host.autoInstallPluginUpdates"
        static let installedBuiltinPlugins = "host.installedBuiltinPlugins"
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

    /// 插件市场索引地址。默认取 Info.plist 的 `ChassisMarketplaceURL`（打包时注入），
    /// 用户或开发期可用 defaults 覆盖，便于自建/本地市场。
    public var marketplaceURL: String {
        didSet { defaults.set(marketplaceURL, forKey: Key.marketplaceURL) }
    }

    /// 市场索引签名公钥（base64 Ed25519）。为空时只有 DEBUG 的本地来源可用。
    public var marketplacePublicKey: String {
        didSet { defaults.set(marketplacePublicKey, forKey: Key.marketplacePublicKey) }
    }

    public var autoCheckPluginUpdates: Bool {
        didSet { defaults.set(autoCheckPluginUpdates, forKey: Key.autoCheckPluginUpdates) }
    }

    /// 自动安装更新。默认关闭：更新可能改变能力声明，导致插件需要重新授权。
    public var autoInstallPluginUpdates: Bool {
        didSet { defaults.set(autoInstallPluginUpdates, forKey: Key.autoInstallPluginUpdates) }
    }

    /// 用户已「安装」的内置插件 ID。全新安装时为空——默认零插件。
    public var installedBuiltinPluginIDs: Set<String> {
        didSet { defaults.set(Array(installedBuiltinPluginIDs), forKey: Key.installedBuiltinPlugins) }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.array(forKey: Key.enabledPlugins) as? [String] ?? []
        enabledPluginIDs = Set(stored)
        // 默认显示菜单栏图标；`object(forKey:)` 为 nil 说明从未写过，取默认值而不是 false。
        showMenuBarIcon = defaults.object(forKey: Key.showMenuBarIcon) as? Bool ?? true
        showSettingsOnLaunch = defaults.object(forKey: Key.showSettingsOnLaunch) as? Bool ?? true
        allowThirdPartyPlugins = defaults.object(forKey: Key.allowThirdPartyPlugins) as? Bool ?? false

        let bundledURL = Bundle.main.object(forInfoDictionaryKey: "ChassisMarketplaceURL") as? String ?? ""
        marketplaceURL = defaults.string(forKey: Key.marketplaceURL) ?? bundledURL
        let bundledKey = Bundle.main.object(forInfoDictionaryKey: "ChassisMarketplacePublicKey") as? String ?? ""
        marketplacePublicKey = defaults.string(forKey: Key.marketplacePublicKey) ?? bundledKey
        autoCheckPluginUpdates = defaults.object(forKey: Key.autoCheckPluginUpdates) as? Bool ?? true
        autoInstallPluginUpdates = defaults.object(forKey: Key.autoInstallPluginUpdates) as? Bool ?? false
        installedBuiltinPluginIDs = Set(defaults.array(forKey: Key.installedBuiltinPlugins) as? [String] ?? [])
    }
}
