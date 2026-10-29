import SwiftUI

/// `@MainActor` 标在协议级别是防止跨线程数据竞争的第一道防线：
/// 插件所有代码都在主线程执行，无法意外触碰 tap 线程。
///
/// `AnyObject` 不是装饰：基座持有唯一实例，插件在订阅闭包中需要 `[weak self]`，
/// `deactivate` 的幂等也建立在「同一对象多次进出」这一前提上。
@MainActor
public protocol FeaturePlugin: AnyObject {
    static var manifest: PluginManifest { get }

    /// 基座只在「用户已开启 + 能力齐备」时创建唯一实例；关闭再开启复用同一实例。
    /// 协议要求 `init()` 是为了让注册表能按类型实例化（`[any FeaturePlugin.Type]` 无法直接 `init()`）。
    init()

    /// 前置条件由基座保证：用户已开启 + requiredCapabilities 齐备。
    /// 若本方法抛错，基座不会调用 `deactivate`，插件必须自己回滚已创建的资源。
    func activate(context: PluginContext) throws

    /// 必须幂等、不得抛错、必须同步完成。
    /// 基座会强制清理订阅与快捷键，但清理不了插件自己的 Timer / Task / NotificationCenter 观察者。
    func deactivate()

    /// 设置页。仅在插件 active 时调用，因此可以安全读取 self 上的状态。
    /// 每次切回该插件都会重新调用；返回值必须绑定到插件持有的 model。
    func makeSettingsView() -> AnyView
}
