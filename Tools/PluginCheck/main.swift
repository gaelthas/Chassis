import Foundation
import PluginAPI
import PluginKit

/// 开发期工具：校验、安装并真实加载一个外部插件包。
/// 用法：swift run PluginCheck /path/to/Plugin.chassisplugin
@main
struct PluginCheckMain {
    static func main() {
        MainActor.assumeIsolated {
            run()
        }
    }

    @MainActor
    private static func run() {
        let arguments = CommandLine.arguments
        guard arguments.count > 1 else {
            print("用法：swift run PluginCheck <Plugin.chassisplugin>")
            exit(2)
        }
        let url = URL(fileURLWithPath: arguments[1])

        do {
            let hostVersion = "1.0.0"
            let installer = PluginInstaller(hostVersion: hostVersion)
            let policy = PluginInstallPolicy(allowedTeamIDs: [], allowThirdParty: true)

            let staged = try installer.inspect(url: url, policy: policy)
            print("① 清单 OK：\(staged.manifest.id) v\(staged.manifest.version) team=\(staged.teamID ?? "adhoc")")
            print("   能力：required=\(staged.manifest.requiredCapabilities) optional=\(staged.manifest.optionalCapabilities)")

            let record = try installer.install(staged)
            print("② 安装 OK：\(record.path)")

            let logStore = LogStore()
            let loader = ExternalPluginLoader(hostVersion: hostVersion, logStore: logStore)
            let registrations = loader.registrations(from: [record])
            guard let registration = registrations.first else {
                print("✗ 清单无法转成注册项")
                exit(1)
            }
            print("③ 注册 OK：\(registration.manifest.id)")

            let suite = UserDefaults(suiteName: "com.gaelthas.chassis.plugincheck") ?? .standard
            suite.removePersistentDomain(forName: "com.gaelthas.chassis.plugincheck")
            let settings = HostSettings(defaults: suite)
            let consents = PluginConsentStore(defaults: suite)
            let gate = PermissionGate()
            let bus = InputBusCore()
            let hotKeys = HotKeyArbitrator()
            let notifier = NotifierImpl(logStore: logStore)
            let registry = PluginRegistry(
                settings: settings,
                gate: gate,
                consents: consents,
                inputBus: bus,
                hotKeys: hotKeys,
                notifier: notifier,
                taskRunner: TaskRunner(),
                logStore: logStore,
                hostVersion: hostVersion
            )

            registry.registerExternal(registrations)
            if registry.needsConsentPrompt(record.id) {
                let granted = registry.grantConsent(record.id, capabilities: registry.declaredCapabilities(of: record.id))
                print("④ 逐插件授权：\(granted ? "已授予" : "拒绝")")
            } else {
                print("④ 逐插件授权：该插件未声明能力，无需确认")
            }

            registry.setEnabled(record.id, enabled: true)
            let state = registry.state(of: record.id)
            print("⑤ 启用后状态：\(state)")
            guard state == .active else {
                print("✗ 插件未激活")
                exit(1)
            }

            let hasSettings = registry.makeSettingsView(for: record.id) != nil
            print("⑥ 设置页：\(hasSettings ? "可用" : "缺失")")

            registry.setEnabled(record.id, enabled: false)
            print("⑦ 停用后状态：\(registry.state(of: record.id))")
            print("   输入源：keyboardTap=\(bus.hasKeyboardTap) mouseTap=\(bus.hasMouseTap) pointer=\(bus.hasPointerMonitor)")

            try installer.uninstall(id: record.id)
            print("⑧ 卸载 OK（文件已移入废纸篓）")
            print("✓ 外部插件全链路通过")
        } catch {
            print("✗ 失败：\(error.localizedDescription)")
            exit(1)
        }
    }
}
