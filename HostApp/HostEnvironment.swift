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
    let consents = PluginConsentStore()
    let inputBus = InputBusCore()
    let hotKeys = HotKeyArbitrator()
    let taskRunner = TaskRunner()
    let notifier: NotifierImpl
    let registry: PluginRegistry
    let hostLogger: HostLogger
    let installer: PluginInstaller
    let marketplace: PluginUpdateCenter
    private let externalLoader: ExternalPluginLoader

    var selectedPane: SettingsPane = .general
    /// 开机自启注册失败的说明；为空表示无错误。
    var launchAtLoginError: String?
    var lastOpenSettingsFailed = false

    private var bootstrapped = false

    init() {
        notifier = NotifierImpl(logStore: logStore)
        hostLogger = HostLogger(subsystem: AppIdentity.bundleIdentifier, store: logStore)
        installer = PluginInstaller(hostVersion: AppIdentity.version)
        externalLoader = ExternalPluginLoader(hostVersion: AppIdentity.version, logStore: logStore)
        let registry = PluginRegistry(
            settings: settings,
            gate: gate,
            consents: consents,
            inputBus: inputBus,
            hotKeys: hotKeys,
            notifier: notifier,
            taskRunner: taskRunner,
            logStore: logStore,
            hostVersion: AppIdentity.version
        )
        self.registry = registry
        marketplace = PluginUpdateCenter(
            installer: installer,
            settings: settings,
            hostVersion: AppIdentity.version,
            logStore: logStore
        )
        marketplace.onInstalled = { [weak self] in
            self?.refreshExternalPlugins()
        }
    }

    /// 启动时序（§8）：读配置 → 取 manifest → 渲染 UI → 激活已启用插件。
    /// 空载分支：enabled 集合为空时这里不会创建 tap、不会检查权限、不会实例化任何插件。
    func bootstrap() {
        guard !bootstrapped else { return }
        bootstrapped = true

        registry.register(PluginCatalog.installed(settings.installedBuiltinPluginIDs))
        refreshExternalPlugins()

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
        // 市场检查放在插件激活之后：避免与首屏、权限探测抢时序。
        marketplace.startAutomaticUpdates()
        // 空载承诺的可观测证据：插件全关时 tap 数必须为 0（验收 A1）。
        hostLogger.info(
            "基座启动完成：\(registry.installedCount) 个插件，\(registry.enabledCount) 个已激活，活动输入源 \(inputBus.activeTapCount) 个"
        )
    }

    // MARK: - 内置插件（需手动安装）

    var bundledOffers: [PluginManifest] {
        PluginCatalog.offers.map { $0.manifest }
    }

    func isBundledPlugin(_ id: String) -> Bool {
        PluginCatalog.isOffer(id)
    }

    func isBundledPluginInstalled(_ id: String) -> Bool {
        settings.installedBuiltinPluginIDs.contains(id)
    }

    /// 安装内置插件：只写注册集合，不激活；启用前仍要过逐插件授权。
    func installBundledPlugin(id: String) {
        guard PluginCatalog.isOffer(id) else { return }
        settings.installedBuiltinPluginIDs.insert(id)
        registry.register(PluginCatalog.installed(settings.installedBuiltinPluginIDs))
        // 重新按启用/授权状态求值：若该插件此前已被启用，安装后应立即回到原状态。
        registry.activateAll()
        hostLogger.info("已安装内置插件：\(id)")
    }

    func uninstallBundledPlugin(id: String) {
        registry.unregister(id: id)
        settings.installedBuiltinPluginIDs.remove(id)
        hostLogger.info("已卸载内置插件：\(id)")
    }

    // MARK: - 外部插件

    private var installPolicy: PluginInstallPolicy {
        PluginInstallPolicy(
            allowedTeamIDs: Set([AppIdentity.teamID].compactMap { $0 }),
            allowThirdParty: settings.allowThirdPartyPlugins
        )
    }

    /// 只读校验，不做任何安装副作用；用于安装确认页。
    func inspectPlugin(at url: URL) throws -> StagedPlugin {
        try installer.inspect(url: url, policy: installPolicy)
    }

    func install(_ staged: StagedPlugin) throws {
        try installer.install(staged)
        refreshExternalPlugins()
        hostLogger.info("已安装外部插件：\(staged.manifest.id) v\(staged.manifest.version)")
    }

    func uninstallExternalPlugin(id: String) throws {
        registry.unregister(id: id)
        try installer.uninstall(id: id)
        hostLogger.info("已卸载外部插件：\(id)")
    }

    /// 重新扫描安装目录：安装、升级、卸载后调用。
    func refreshExternalPlugins() {
        let records = installer.records
        registry.registerExternal(externalLoader.registrations(from: records))
        // 安装/升级后重新求值：升级不应把已启用的插件留成 disabled。
        registry.reconcile()
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
