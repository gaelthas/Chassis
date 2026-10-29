import Foundation
import PluginAPI
import PluginKit

/// 开发期工具：用真正的 `PluginUpdateCenter` 走一遍市场链路。
/// 用法：swift run MarketCheck <index-url> [public-key-base64]
@main
struct MarketCheckMain {
    static func main() async {
        await run()
    }

    @MainActor
    private static func run() async {
        let arguments = CommandLine.arguments
        guard arguments.count > 1, let url = URL(string: arguments[1]) else {
            print("用法：swift run MarketCheck <index-url> [public-key-base64]")
            exit(2)
        }
        let publicKey = arguments.count > 2 ? arguments[2] : ""
        let hostVersion = "1.0.0"

        do {
            let suiteName = "com.gaelthas.chassis.marketcheck"
            let suite = UserDefaults(suiteName: suiteName) ?? .standard
            suite.removePersistentDomain(forName: suiteName)

            let settings = HostSettings(defaults: suite)
            settings.marketplaceURL = url.absoluteString
            settings.marketplacePublicKey = publicKey
            settings.allowThirdPartyPlugins = true

            let logStore = LogStore()
            let installer = PluginInstaller(hostVersion: hostVersion)
            let loader = ExternalPluginLoader(hostVersion: hostVersion, logStore: logStore)
            let registry = PluginRegistry(
                settings: settings,
                gate: PermissionGate(),
                consents: PluginConsentStore(defaults: suite),
                inputBus: InputBusCore(),
                hotKeys: HotKeyArbitrator(),
                notifier: NotifierImpl(logStore: logStore),
                taskRunner: TaskRunner(),
                logStore: logStore,
                hostVersion: hostVersion
            )

            let center = PluginUpdateCenter(
                installer: installer,
                settings: settings,
                hostVersion: hostVersion,
                logStore: logStore
            )
            center.onInstalled = {
                registry.registerExternal(loader.registrations(from: installer.records))
            }

            await center.refresh()
            print("① 索引状态：\(center.status)")
            for item in center.items {
                print("   - \(item.plugin.id) v\(item.plugin.version) → \(item.state)")
            }
            guard let target = center.items.first(where: { if case .notInstalled = $0.state { return true } else { return false } }) else {
                print("✗ 索引里没有可安装的插件")
                exit(1)
            }

            await center.install(id: target.id)
            print("② 安装结果：\(center.items.first { $0.id == target.id }?.state ?? .notInstalled)")

            _ = registry.grantConsent(target.id, capabilities: registry.declaredCapabilities(of: target.id))
            registry.setEnabled(target.id, enabled: true)
            print("③ 启用后状态：\(registry.state(of: target.id))")
            print("④ 设置页：\(registry.makeSettingsView(for: target.id) != nil ? "可用" : "缺失")")

            // ⑤ 用一个「版本更高」的索引验证更新检测（不改动仓库里的包，只改临时索引）。
            if publicKey.isEmpty || arguments.count > 3 {
                if let upgradeIndex = try makeUpgradeIndex(from: url, bumpTo: "9.9.9") {
                    settings.marketplaceURL = upgradeIndex.absoluteString
                    settings.marketplacePublicKey = ""  // 临时索引未签名，DEBUG 本地来源放行
                    await center.refresh()
                    let state = center.items.first { $0.id == target.id }?.state
                    print("⑤ 高版本索引检测：\(state ?? .notInstalled)")
                    if case .updateAvailable = state {} else {
                        print("✗ 未检测到可用更新")
                        exit(1)
                    }
                    try? FileManager.default.removeItem(at: upgradeIndex)
                }
            }

            registry.setEnabled(target.id, enabled: false)
            try installer.uninstall(id: target.id)
            print("⑥ 卸载 OK")
            print("✓ 插件市场全链路通过（可用更新 \(center.availableUpdateCount) 个）")
        } catch {
            print("✗ 失败：\((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)")
            exit(1)
        }
    }

    /// 把索引里的第一个插件版本改成 `bumpTo`，写到临时文件。签名索引也能处理：取 payload 原文。
    @MainActor
    private static func makeUpgradeIndex(from url: URL, bumpTo: String) throws -> URL? {
        let data = try Data(contentsOf: url)
        let payloadData: Data
        if let envelope = try? JSONDecoder().decode(MarketplaceEnvelope.self, from: data) {
            payloadData = Data(envelope.payload.utf8)
        } else {
            payloadData = data
        }
        guard var object = try JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
              var plugins = object["plugins"] as? [[String: Any]],
              !plugins.isEmpty else {
            return nil
        }
        plugins[0]["version"] = bumpTo
        object["plugins"] = plugins
        let upgraded = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("marketcheck-upgrade-\(UUID().uuidString).json")
        try upgraded.write(to: destination)
        return destination
    }
}
