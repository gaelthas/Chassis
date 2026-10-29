import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import IOKit.hid
import Observation
import PluginAPI

/// 权限门控：集中探测、收敛申请、统计消费者。
///
/// 硬规则（§6.2）：
/// 1. 启动不调用 `request`，`request` 唯一来源是用户点击；
/// 2. 同一 Capability 单次启动最多弹一次系统框，重复调用改为跳转系统设置；
/// 3. 权限被收回时相关插件迁到 `missingCapabilities` 并取消其全部订阅。
@MainActor
@Observable
public final class PermissionGate {
    /// 缓存的门控结果。UI 与插件读的都是这一份，避免高频轮询系统接口。
    private var cache: [Capability: Bool] = [:]
    private var restricted: Set<Capability> = []
    private var requestedOnce: Set<Capability> = []

    /// 权限变化后由基座注册表接管（重新判定插件状态）。
    @ObservationIgnored public var onChange: (() -> Void)?
    /// 需要「当前有多少个启用插件需要它」的统计来源。
    @ObservationIgnored public var consumersProvider: ((Capability) -> [String])?
    /// 用户点「打开系统设置」时的实际执行者（HostApp 注入，便于测试与失败回退）。
    @ObservationIgnored public var openSystemSettings: ((Capability) -> Bool)?

    /// 记录最近一次跳转系统设置的结果，权限页据此展示「请手动打开」的回退文案。
    public private(set) var lastOpenSettingsFailed = false

    public init() {
        refresh()
    }

    // MARK: - 查询

    public func status(of capability: Capability) -> Bool {
        cache[capability] ?? probe(capability)
    }

    /// 受限表示被 MDM 或系统策略禁用。
    ///
    /// 诚实说明：macOS 没有公开 API 能稳定区分「未授权」与「被策略禁用」，
    /// 因此这里只对能够确认的情形返回 true，其余返回 false。
    /// UI 仍然保留第三态，等未来有可靠探测源时可直接接入（P4：不假装有保证）。
    public func isRestricted(_ capability: Capability) -> Bool {
        restricted.contains(capability)
    }

    public func granted(_ set: Set<Capability>) -> Set<Capability> {
        set.filter { status(of: $0) }
    }

    public func consumers(of capability: Capability) -> [String] {
        consumersProvider?(capability) ?? []
    }

    /// 全量重探测。由 `didBecomeActive`、权限页出现、首启时触发。
    public func refresh() {
        var next: [Capability: Bool] = [:]
        for capability in Capability.allCases {
            next[capability] = probe(capability)
        }
        let changed = next != cache
        cache = next
        // 已授权的项不再需要「等待/去系统设置」的提示。
        for (capability, granted) in next where granted {
            if outcomes[capability] != .granted {
                outcomes[capability] = .granted
            }
        }
        if changed { onChange?() }
    }

    // MARK: - 申请

    /// 一次申请的结果。UI 用它给出「接下来该做什么」，而不是点了没反应。
    public enum RequestOutcome: Sendable, Equatable {
        /// 已授权。
        case granted
        /// 已触发系统弹框，等待用户在本应用或系统设置里操作。
        case waitingForSystem
        /// 系统没有弹框（此前已拒绝或被策略限制），必须手动去系统设置。
        case needsSystemSettings
        /// 被 MDM 或系统策略禁用，申请必然无效。
        case restricted
    }

    public private(set) var outcomes: [Capability: RequestOutcome] = [:]

    @ObservationIgnored private var verificationTasks: [Capability: Task<Void, Never>] = [:]

    /// 协议入口（插件用）。语义与权限页按钮一致，只是没有返回值。
    public func request(_ capability: Capability) {
        _ = requestFromUserInterface(capability)
    }

    /// 权限页按钮入口：返回结果供 UI 展示，避免「点了没有任何变化」。
    @discardableResult
    public func requestFromUserInterface(_ capability: Capability) -> RequestOutcome {
        if isRestricted(capability) {
            outcomes[capability] = .restricted
            return .restricted
        }
        if status(of: capability) {
            outcomes[capability] = .granted
            return .granted
        }
        // 单次启动内每种权限最多弹一次框；之后只能引导用户去系统设置。
        if requestedOnce.contains(capability) {
            openSettingsOrWarn(capability)
            outcomes[capability] = .needsSystemSettings
            return .needsSystemSettings
        }
        requestedOnce.insert(capability)

        switch capability {
        case .accessibility:
            // kAXTrustedCheckOptionPrompt 是全局 var，Swift 6 下不能直接引用；
            // 其值固定为 "AXTrustedCheckOptionPrompt"，用字面量等价。
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        case .inputMonitoring:
            let requested = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
            // 已明确拒绝时系统不会再弹框，request 会直接返回 false——此时必须引导去系统设置，
            // 否则用户看到的就是「点了没反应」。
            if !requested, IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeDenied {
                openSettingsOrWarn(capability)
                outcomes[capability] = .needsSystemSettings
                return .needsSystemSettings
            }
        case .screenCapture:
            _ = CGRequestScreenCaptureAccess()
        }

        refresh()
        if status(of: capability) {
            outcomes[capability] = .granted
            return .granted
        }

        outcomes[capability] = .waitingForSystem
        scheduleVerification(for: capability)
        return .waitingForSystem
    }

    /// 申请后轮询若干次：用户可能正在系统框上点「打开系统设置」，或直接去开关里授权。
    /// 若始终没有变化，就把状态改为「需要手动去系统设置」，让 UI 明确告知原因。
    private func scheduleVerification(for capability: Capability) {
        verificationTasks[capability]?.cancel()
        verificationTasks[capability] = Task { [weak self] in
            for _ in 0..<10 {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled, let self else { return }
                self.refresh()
                guard self.status(of: capability) else { continue }
                self.outcomes[capability] = .granted
                return
            }
            guard let self, self.outcomes[capability] != .granted else { return }
            self.outcomes[capability] = .needsSystemSettings
        }
    }

    /// 用户点「重新检测」：有些系统版本对已运行进程缓存 TCC 结果，
    /// 主动刷新一次可以立刻反映外部变化。
    public func recheck(_ capability: Capability) {
        refresh()
        if status(of: capability) {
            outcomes[capability] = .granted
        }
    }

    /// 用户点「打开系统设置」。
    public func openSystemSettingsPane(_ capability: Capability) {
        openSettingsOrWarn(capability)
    }

    private func openSettingsOrWarn(_ capability: Capability) {
        let opened = openSystemSettings?(capability) ?? false
        lastOpenSettingsFailed = !opened
    }

    // MARK: - 探测

    private func probe(_ capability: Capability) -> Bool {
        switch capability {
        case .accessibility:
            return AXIsProcessTrusted()
        case .inputMonitoring:
            // `unknown` 是瞬时状态（系统刚唤醒、辅助进程重启），不能当作「已收回」，
            // 否则会出现「刚启用就报缺少权限」的抖动。
            switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
            case kIOHIDAccessTypeGranted: return true
            case kIOHIDAccessTypeDenied: return false
            default: return cache[.inputMonitoring] ?? false
            }
        case .screenCapture:
            return CGPreflightScreenCaptureAccess()
        }
    }
}
