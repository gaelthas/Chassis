import AppKit
import Foundation
import Observation
import PluginAPI
import UserNotifications

/// 通知服务：授权、节流、去重、合并、前台抑制、点击路由。
///
/// 通知不是 `Capability`：走 `UNUserNotificationCenter` 的独立授权体系，
/// 被拒时插件照常工作，只是不发通知（§6.8）。
@MainActor
@Observable
public final class NotifierImpl: NSObject {
    public private(set) var authorization: NotificationAuthorization = .notDetermined

    @ObservationIgnored private var hasRequestedAuthorization = false
    @ObservationIgnored private var lastPostByOwner: [String: Date] = [:]
    @ObservationIgnored private var globalPostTimes: [Date] = []
    @ObservationIgnored private var coalescingTimes: [String: Date] = [:]
    @ObservationIgnored private var clickHandlers: [String: @MainActor () -> Void] = [:]
    /// identifier → owner。pluginID 本身含点号，无法从 identifier 反推，因此显式记录。
    @ObservationIgnored private var ownersByIdentifier: [String: String] = [:]

    @ObservationIgnored private let logStore: LogStore
    /// 非 .app 环境（如开发期 CLI 工具）没有 bundleProxy，`UNUserNotificationCenter.current()`
    /// 会直接抛 NSException；这里按需创建并允许为 nil。
    @ObservationIgnored private lazy var center: UNUserNotificationCenter? = {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return nil }
        return UNUserNotificationCenter.current()
    }()

    /// 点击历史通知时判断插件是否仍 active；非 active 时忽略点击（§6.8）。
    @ObservationIgnored public var isPluginActive: ((String) -> Bool)?
    /// 基座设置窗口为 key window 时不弹横幅，避免噪音。
    @ObservationIgnored public var isSettingsWindowKey: () -> Bool = { false }

    /// 节流常量：插件不可配置。
    private enum Limits {
        static let perPluginInterval: TimeInterval = 5
        static let globalMinimumInterval: TimeInterval = 2
        static let globalWindow: TimeInterval = 60
        static let globalWindowLimit = 10
        static let coalescingWindow: TimeInterval = 60
    }

    public init(logStore: LogStore) {
        self.logStore = logStore
        super.init()
        center?.delegate = self
        Task { [weak self] in
            await self?.refreshAuthorization()
        }
    }

    // MARK: - 授权

    public func requestAuthorization() async -> Bool {
        if hasRequestedAuthorization {
            return authorization == .authorized
        }
        hasRequestedAuthorization = true
        guard let center else {
            authorization = .notDetermined
            return false
        }
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound])
            authorization = granted ? .authorized : .denied
            return granted
        } catch {
            logStore.append(level: .warning, pluginID: nil, message: "通知授权申请失败：\(error.localizedDescription)")
            authorization = .denied
            return false
        }
    }

    /// `UNNotificationSettings` 不是 Sendable，直接把整个对象 await 回主线程在 Swift 6 下是非法的；
    /// 只把它里面的 `authorizationStatus`（Sendable 枚举）带回来。
    private nonisolated static func currentAuthorizationStatus() async -> UNAuthorizationStatus? {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return nil }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return settings.authorizationStatus
    }

    public func refreshAuthorization() async {
        guard center != nil else {
            authorization = .notDetermined
            return
        }
        guard let status = await Self.currentAuthorizationStatus() else {
            authorization = .notDetermined
            return
        }
        switch status {
        case .authorized, .provisional, .ephemeral:
            authorization = .authorized
        case .denied:
            authorization = .denied
        case .notDetermined:
            authorization = .notDetermined
        @unknown default:
            authorization = .notDetermined
        }
    }

    // MARK: - 发送

    /// 由插件的 `Notifier` 门面调用（门面负责带上 owner）。
    func post(_ notification: PluginNotification, owner: String) {
        let now = Date()

        guard authorization == .authorized else {
            logStore.append(level: .debug, pluginID: owner, message: "通知被丢弃：未授权")
            return
        }
        if isSettingsWindowKey() {
            logStore.append(level: .debug, pluginID: owner, message: "通知被前台抑制")
            return
        }
        if let last = lastPostByOwner[owner], now.timeIntervalSince(last) < Limits.perPluginInterval {
            logStore.append(level: .debug, pluginID: owner, message: "通知被丢弃：插件最小间隔 5s")
            return
        }
        globalPostTimes.removeAll { now.timeIntervalSince($0) > Limits.globalWindow }
        if let last = globalPostTimes.last, now.timeIntervalSince(last) < Limits.globalMinimumInterval {
            logStore.append(level: .debug, pluginID: owner, message: "通知被丢弃：全局速率 1 条/2s")
            return
        }
        if globalPostTimes.count >= Limits.globalWindowLimit {
            logStore.append(level: .debug, pluginID: owner, message: "通知被丢弃：全局 60s 上限")
            return
        }
        if let key = notification.coalescingKey {
            let composite = "\(owner)|\(key)"
            if let last = coalescingTimes[composite], now.timeIntervalSince(last) < Limits.coalescingWindow {
                // 相同 coalescingKey 在窗口期内只保留最新一条：覆盖同 identifier 的请求即可。
                logStore.append(level: .debug, pluginID: owner, message: "通知被合并：\(key)")
            }
            coalescingTimes[composite] = now
        }

        lastPostByOwner[owner] = now
        globalPostTimes.append(now)

        let identifier = Self.identifier(owner: owner, id: notification.id)
        ownersByIdentifier[identifier] = owner
        if let onClick = notification.onClick {
            clickHandlers[identifier] = onClick
        } else {
            clickHandlers.removeValue(forKey: identifier)
        }

        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        if notification.priority == .normal {
            content.sound = .default
        }

        guard let center else {
            logStore.append(level: .debug, pluginID: owner, message: "通知被丢弃：无应用 bundle")
            return
        }

        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        center.add(request) { [logStore, owner] error in
            if let error {
                logStore.append(level: .warning, pluginID: owner, message: "通知投递失败：\(error.localizedDescription)")
            }
        }
    }

    func clearOwner(_ owner: String) {
        for (identifier, recordedOwner) in ownersByIdentifier where recordedOwner == owner {
            clickHandlers.removeValue(forKey: identifier)
            ownersByIdentifier.removeValue(forKey: identifier)
        }
    }

    private static func identifier(owner: String, id: String) -> String {
        "\(owner).\(id)"
    }
}

extension NotifierImpl: UNUserNotificationCenterDelegate {
    public nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list])
    }

    public nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let identifier = response.notification.request.identifier
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.handleClick(identifier: identifier)
            }
        }
        completionHandler()
    }

    private func handleClick(identifier: String) {
        guard let owner = ownersByIdentifier[identifier] else { return }
        guard isPluginActive?(owner) == true else {
            logStore.append(level: .info, pluginID: owner, message: "忽略通知点击：插件非 active")
            return
        }
        guard let handler = clickHandlers[identifier] else { return }
        handler()
    }
}
