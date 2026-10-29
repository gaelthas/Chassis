import Foundation
import Observation
import PluginAPI
import PluginKit
import PluginSupport

/// 依赖组装的唯一位置。所有基座服务在这里创建一次，随后注入注册表与 UI。
@MainActor
@Observable
final class HostEnvironment {
    static let shared = HostEnvironment()

    let settings = HostSettings()
    let logStore = LogStore()
    let gate = PermissionGate()
    let inputBus = InputBusCore()
    let hotKeys = HotKeyArbitrator()
    let taskRunner = TaskRunner()
    let notifier: NotifierImpl
    let registry: PluginRegistry
    let hostLogger: HostLogger

    var selectedPane: SettingsPane = .general
    /// 开机自启注册失败的说明；为空表示无错误。
    var launchAtLoginError: String?
    var lastOpenSettingsFailed = false

    private var bootstrapped = false

    init() {
        notifier = NotifierImpl(logStore: logStore)
        hostLogger = HostLogger(subsystem: AppIdentity.bundleIdentifier, store: logStore)
        registry = PluginRegistry(
            settings: settings,
            gate: gate,
            inputBus: inputBus,
            hotKeys: hotKeys,
            notifier: notifier,
            taskRunner: taskRunner,
            logStore: logStore,
            hostVersion: AppIdentity.version
        )
    }

    /// 启动时序（§8）：读配置 → 取 manifest → 渲染 UI → 激活已启用插件。
    /// 空载分支：enabled 集合为空时这里不会创建 tap、不会检查权限、不会实例化任何插件。
    func bootstrap() {
        guard !bootstrapped else { return }
        bootstrapped = true

        registry.register(PluginCatalog.all)

        gate.openSystemSettings = { capability in
            SystemSettingsPane.open(capability)
        }
        notifier.isSettingsWindowKey = {
            SettingsWindowController.shared.isSettingsWindowKey
        }
        gate.onChange = { [weak self] in
            self?.registry.reconcile()
        }

        registry.activateAll()
        // 空载承诺的可观测证据：插件全关时 tap 数必须为 0（验收 A1）。
        hostLogger.info(
            "基座启动完成：\(registry.installedCount) 个插件，\(registry.enabledCount) 个已激活，活动输入源 \(inputBus.activeTapCount) 个"
        )
    }

    /// 从系统设置返回时重探测权限，驱动 missingCapabilities ↔ active 自动迁移。
    func refreshAfterActivation() {
        gate.refresh()
        Task { await notifier.refreshAuthorization() }
    }

    var diagnosticsText: String {
        DiagnosticsExporter.text(environment: self)
    }
}
