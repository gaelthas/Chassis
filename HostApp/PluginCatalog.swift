import DockActions
import Foundation
import PluginAPI
import SlowQuit
import WindowSwitcher
#if DEBUG
import Harness
#endif

/// 插件注册表：静态链接模型下唯一可发现插件的入口。
///
/// 新增插件只改这一行；注册只登记类型，不实例化——`manifest` 是 static。
/// `@MainActor` 不能省：`FeaturePlugin` 是主 actor 隔离的协议。
@MainActor
enum PluginCatalog {
    static let all: [any FeaturePlugin.Type] = {
        var plugins: [any FeaturePlugin.Type] = [
            DockActionsPlugin.self,
            SlowQuitPlugin.self,
            WindowSwitcherPlugin.self,
        ]
        #if DEBUG
        // 探针插件仅调试构建注册：它不是产品功能，不随正式版发布。
        plugins.append(HarnessPlugin.self)
        #endif
        return plugins
    }()
}
