import Foundation

/// 通知走 `UNUserNotificationCenter`，是独立于 TCC 的授权体系，
/// 因此不属于 `Capability`：被拒时插件应照常工作，只是不发通知（§6.8）。
@MainActor
public protocol Notifier {
    var authorization: NotificationAuthorization { get }

    /// 请求授权。基座全局只申请一次；重复调用返回既有状态，不重复弹框。
    /// 仅允许在用户手势中调用。
    func requestAuthorization() async -> Bool

    /// 发送一条通知。节流、去重、前台抑制全部由基座处理。
    func post(_ notification: PluginNotification)
}

public struct PluginNotification {
    /// 插件内唯一，用于替换同一条通知。
    public let id: String
    public let title: String
    public let body: String
    public let priority: NotificationPriority
    /// 相同 key 在窗口期内只保留最新一条。
    public let coalescingKey: String?
    /// 可选；仅插件 active 时有效。
    public let onClick: (@MainActor () -> Void)?

    public init(
        id: String,
        title: String,
        body: String,
        priority: NotificationPriority = .normal,
        coalescingKey: String? = nil,
        onClick: (@MainActor () -> Void)? = nil
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.priority = priority
        self.coalescingKey = coalescingKey
        self.onClick = onClick
    }
}

public enum NotificationPriority {
    case normal
    case low
}

public enum NotificationAuthorization {
    case notDetermined
    case denied
    case authorized
}
