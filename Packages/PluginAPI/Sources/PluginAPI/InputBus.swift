import CoreGraphics
import Foundation

/// 插件感知输入的**唯一**途径。
///
/// 全应用最多 1 个键盘 tap + 1 个鼠标 tap，由基座独占创建；按输入源分别引用计数，
/// 零订阅者 = 零 tap（这是「纯基座」空载承诺的实现依据）。
@MainActor
public protocol InputBus {
    /// 订阅有效鼠标点击。基座已在 tap 侧完成时间差 + 位移差判定，并附带 button / clickCount。
    func subscribeToClick(_ handler: @escaping @MainActor (ClickContext) -> Void) -> Subscription

    /// 订阅指针移动（基座已节流：≤60Hz + 位移阈值）。
    func subscribeToPointerMove(_ handler: @escaping @MainActor (CGPoint) -> Void) -> Subscription

    /// 订阅键盘事件。三段式：`KeyFilter` 预筛 → `syncIntercept` 同步拦截 → `handler` 主线程业务。
    ///
    /// `syncIntercept` 跑在 tap 线程：只允许读标量、位运算、读 `AtomicFlag`；
    /// 禁止内存分配、加锁、`Dispatch`、访问 AppKit。返回 `.consume` 才会吞掉事件。
    func subscribeToKey(
        _ filter: KeyFilter,
        syncIntercept: (@Sendable (KeyEvent) -> KeyIntercept)?,
        handler: @escaping @MainActor (KeyEvent) -> Void
    ) -> Subscription

    /// 订阅输入源降级通知。这是「事件突然静默消失」时插件唯一能被通知到的途径，
    /// 有进行中会话（按住未完成、拖拽中途）的插件必须订阅。
    /// 不参与引用计数，不产生任何系统资源。
    func subscribeToInterruptions(_ handler: @escaping @MainActor (InputInterruption) -> Void) -> Subscription
}

public struct InputInterruption: Sendable {
    /// 哪一路输入失效。
    public let source: InputSource
    /// 为什么失效。
    public let reason: InterruptionReason
    /// 基座是否已自动重建成功。
    public let recovered: Bool

    public init(source: InputSource, reason: InterruptionReason, recovered: Bool) {
        self.source = source
        self.reason = reason
        self.recovered = recovered
    }
}

public enum InputSource: Sendable, Hashable {
    case keyboard
    case pointer
}

public enum InterruptionReason: Sendable, Hashable {
    /// 系统因回调超时禁用 tap。
    case timeoutDisabled
    /// 用户在系统设置中收回授权。
    case permissionRevoked
    /// 创建失败，通常是权限缺失。
    case tapCreationFailed
}

/// 订阅句柄。幂等：重复 `cancel()` 安全；`cancel()` 之后 handler 不再被调用。
/// 引用类型，复制句柄与否都不影响语义。
///
/// 标 `@MainActor`：订阅与取消都发生在主线程（`InputBus` 本身是 Main Actor 的），
/// 这样 tap 线程永远只读不可变快照，不会碰到这里的可变状态。
@MainActor
public final class Subscription {
    private var cancelAction: (() -> Void)?

    public init(onCancel: @escaping @MainActor () -> Void) {
        self.cancelAction = onCancel
    }

    public func cancel() {
        let action = cancelAction
        cancelAction = nil
        action?()
    }

    public var isCancelled: Bool { cancelAction == nil }
}
