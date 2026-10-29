import SwiftUI

/// 基座交给插件的唯一句柄。七个成员：五项能力入口 + 两项基础设施（§5.5）。
@MainActor
public protocol PluginContext: AnyObject {
    var pluginID: String { get }
    var hostVersion: String { get }
    var store: PluginStore { get }
    var inputBus: InputBus { get }
    var hotKeys: HotKeyService { get }
    var permissions: PermissionService { get }
    var notifier: Notifier { get }
    /// 刻意不叫 Logger：插件一旦 import os，两个 Logger 会撞名。
    var logger: PluginLogger { get }

    /// 统一的后台执行上下文（执行位置，不是后台任务容器）。
    /// 可能因跨进程等待而变慢的调用（AX / 窗口枚举 / 同步截图）都必须包裹其中。
    /// 闭包为 `@Sendable`，编译期阻止捕获 Main Actor 状态；全局串行、每次调用独立、错误原样透传。
    func performBackground<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T
}

// MARK: - 权限

@MainActor
public protocol PermissionService {
    /// 基座门控结果的只读暴露。插件也可自行调用 AXIsProcessTrusted() 等，二者等价。
    func status(of capability: Capability) -> Bool

    /// 被 MDM 或其他系统策略禁用。此时 request 必然无效，UI 应说明原因而不是给一个点了没反应的按钮。
    func isRestricted(_ capability: Capability) -> Bool

    /// 相对当前插件声明的缺失项。
    var missing: Set<Capability> { get }

    /// 仅允许在用户手势中调用。同一次启动内每种权限最多触发一次系统弹窗，重复调用转为跳转系统设置。
    func request(_ capability: Capability)
}

// MARK: - 快捷键

@MainActor
public protocol HotKeyService {
    /// 注册当前插件的快捷键。冲突时抛 `HotKeyError`。
    func register(_ spec: HotKeySpec, handler: @escaping @MainActor () -> Void) throws

    /// 用户改键时调用。基座保证原子性：新键注册失败则保留旧键，handler 不变。
    func update(_ spec: HotKeySpec) throws

    /// 查询该组合键当前是否可用。调用者身份由 context 决定，参数中不传 pluginID。
    func availability(of spec: HotKeySpec) -> HotKeyAvailability

    /// 主动注销本插件的快捷键。可省略——deactivate 时基座统一注销。
    func unregister()
}
