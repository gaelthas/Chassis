import DockActions
import DockHoverPreview
import Foundation
import PluginAPI
import SlowQuit
import UsageStatistics
import WindowSwitcher
#if DEBUG
import Harness
#endif

/// 插件注册表：静态链接模型下唯一可发现插件的入口。
///
/// 与早期实现的关键差异：`offers` 是**可安装清单**，不是注册表。
/// 全新安装后插件列表为空，用户必须逐个点「安装」才会进入注册表（并写入
/// `HostSettings.installedBuiltinPluginIDs`）。这样「默认零插件」与外部插件安装后
/// 的体验一致：安装 ≠ 启用，启用前还要过逐插件授权。
///
/// `@MainActor` 不能省：`FeaturePlugin` 是主 actor 隔离的协议。
@MainActor
enum PluginCatalog {
    /// 随应用分发的插件（仍需手动安装）。
    static let offers: [any FeaturePlugin.Type] = {
        var plugins: [any FeaturePlugin.Type] = [
            DockActionsPlugin.self,
            SlowQuitPlugin.self,
            WindowSwitcherPlugin.self,
            DockHoverPreviewPlugin.self,
            UsageStatisticsPlugin.self,
        ]
        #if DEBUG
        // 探针插件仅调试构建可见，同样需要手动安装。
        plugins.append(HarnessPlugin.self)
        #endif
        return plugins
    }()

    /// 只把用户安装过的内置插件交给注册表。
    static func installed(_ ids: Set<String>) -> [any FeaturePlugin.Type] {
        offers.filter { ids.contains($0.manifest.id) }
    }

    static func isOffer(_ id: String) -> Bool {
        offers.contains { $0.manifest.id == id }
    }
}
