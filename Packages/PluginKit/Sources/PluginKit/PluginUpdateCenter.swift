import Foundation
import Observation
import PluginAPI

/// 插件市场与自动更新。
///
/// 职责边界：
/// - 只负责「发现新版本 → 下载 → 交给 PluginInstaller」；信任校验完全复用安装链路。
/// - 不碰权限：更新若改变了能力声明，`PluginConsentStore` 的清单指纹会让插件回到「需要重新授权」。
@MainActor
@Observable
public final class PluginUpdateCenter {
    public enum Status: Equatable {
        case idle
        case checking
        case ready
        case failed(String)
    }

    public enum ItemState: Equatable {
        case notInstalled
        case installed
        case updateAvailable(installedVersion: String)
        case incompatible(minimumHostVersion: String)
        case working(String)
        case failed(String)
    }

    public struct Item: Identifiable {
        public let plugin: MarketplacePlugin
        public var state: ItemState

        public var id: String { plugin.id }
    }

    /// 自动检查周期：应用常驻菜单栏，6 小时足够且不会造成负担。
    private let automaticInterval: TimeInterval = 6 * 3600
    private let minimumManualRefreshInterval: TimeInterval = 60

    private let client: MarketplaceClient
    private let installer: PluginInstaller
    private let settings: HostSettings
    private let hostVersion: String
    private let logStore: LogStore
    /// 安装完成后通知基座刷新插件注册表；在初始化后由宿主注入，避免初始化顺序耦合。
    public var onInstalled: @MainActor () -> Void

    private var index: MarketplaceIndex?
    private var autoTask: Task<Void, Never>?

    public private(set) var status: Status = .idle
    public private(set) var items: [Item] = []
    public private(set) var lastChecked: Date?
    public private(set) var lastError: String?

    public init(
        client: MarketplaceClient = MarketplaceClient(),
        installer: PluginInstaller,
        settings: HostSettings,
        hostVersion: String,
        logStore: LogStore,
        onInstalled: @escaping @MainActor () -> Void = {}
    ) {
        self.client = client
        self.installer = installer
        self.settings = settings
        self.hostVersion = hostVersion
        self.logStore = logStore
        self.onInstalled = onInstalled
    }

    // MARK: - 查询

    public var isConfigured: Bool {
        !settings.marketplaceURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var availableUpdateCount: Int {
        items.filter { if case .updateAvailable = $0.state { return true } else { return false } }.count
    }

    public var installableCount: Int {
        items.filter { if case .notInstalled = $0.state { return true } else { return false } }.count
    }

    // MARK: - 检查

    /// 打开市场页时调用：60 秒内不重复请求。
    public func refreshIfStale() async {
        if let lastChecked, Date().timeIntervalSince(lastChecked) < minimumManualRefreshInterval {
            return
        }
        await refresh()
    }

    public func refresh() async {
        guard let url = marketplaceURL else {
            status = .failed(MarketplaceError.notConfigured.localizedDescription)
            lastError = status.message
            return
        }

        status = .checking
        lastError = nil
        do {
            let fetched = try await client.fetchIndex(
                from: url,
                publicKeyBase64: settings.marketplacePublicKey.isEmpty ? nil : settings.marketplacePublicKey
            )
            index = fetched
            apply(fetched)
            lastChecked = Date()
            status = .ready
            logStore.append(
                level: .info,
                pluginID: "com.gaelthas.chassis:market",
                message: "市场索引已更新：\(fetched.plugins.count) 个插件，\(availableUpdateCount) 个可更新"
            )
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            status = .failed(message)
            lastError = message
            logStore.append(level: .error, pluginID: "com.gaelthas.chassis:market", message: "检查更新失败：\(message)")
        }
    }

    private var marketplaceURL: URL? {
        let raw = settings.marketplaceURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, let url = URL(string: raw) else { return nil }
        return url
    }

    private func apply(_ fetched: MarketplaceIndex) {
        let installed = Dictionary(uniqueKeysWithValues: installer.records.map { ($0.id, $0.version) })
        items = fetched.plugins
            .filter { $0.apiVersion <= 1 }
            .map { plugin in
                guard SemanticVersion.isAtLeast(hostVersion, plugin.minHostVersion) else {
                    return Item(plugin: plugin, state: .incompatible(minimumHostVersion: plugin.minHostVersion))
                }
                guard let installedVersion = installed[plugin.id] else {
                    return Item(plugin: plugin, state: .notInstalled)
                }
                if SemanticVersion.isAtLeast(installedVersion, plugin.version) {
                    return Item(plugin: plugin, state: .installed)
                }
                return Item(plugin: plugin, state: .updateAvailable(installedVersion: installedVersion))
            }
            .sorted { lhs, rhs in
                rank(lhs.state) == rank(rhs.state)
                    ? lhs.plugin.name.localizedStandardCompare(rhs.plugin.name) == .orderedAscending
                    : rank(lhs.state) < rank(rhs.state)
            }
    }

    private func rank(_ state: ItemState) -> Int {
        switch state {
        case .updateAvailable: 0
        case .notInstalled: 1
        case .working: 2
        case .failed: 3
        case .installed: 4
        case .incompatible: 5
        }
    }

    // MARK: - 安装

    public func install(id: String) async {
        guard let position = items.firstIndex(where: { $0.id == id }) else { return }
        let plugin = items[position].plugin
        items[position].state = .working("正在下载…")

        do {
            let staging = FileManager.default.temporaryDirectory
                .appendingPathComponent("ChassisMarketplace", isDirectory: true)
            let archive = try await client.download(plugin, into: staging)

            items[position].state = .working("正在校验…")
            let policy = PluginInstallPolicy(
                allowedTeamIDs: Set([AppIdentity.teamID].compactMap { $0 }),
                allowThirdParty: settings.allowThirdPartyPlugins
            )
            let staged = try installer.inspect(url: archive, policy: policy)

            // 市场只能分发它索引里声明的那个插件，防止「挂羊头卖狗肉」。
            guard staged.manifest.id == plugin.id else {
                throw MarketplaceError.downloadFailed("包内插件 ID（\(staged.manifest.id)）与索引不一致")
            }

            let previousCapabilities = installer.installedCapabilities(id: plugin.id)
            items[position].state = .working("正在安装…")
            try installer.install(staged)
            onInstalled()

            items[position].state = .installed
            logStore.append(
                level: .info,
                pluginID: "com.gaelthas.chassis:market",
                message: "已安装 \(plugin.id) v\(plugin.version)"
            )

            if let previousCapabilities {
                let changed = previousCapabilities.required != Set(staged.manifest.requiredCapabilities)
                    || previousCapabilities.optional != Set(staged.manifest.optionalCapabilities)
                if changed {
                    logStore.append(
                        level: .warning,
                        pluginID: plugin.id,
                        message: "更新改变了能力声明：插件已暂停，需要重新确认授权"
                    )
                }
            }

            // 重新按索引计算一次，避免「安装完仍显示可安装」。
            if let index {
                apply(index)
            }
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            items[position].state = .failed(message)
            logStore.append(level: .error, pluginID: "com.gaelthas.chassis:market", message: "安装 \(plugin.id) 失败：\(message)")
        }
    }

    /// 自动更新只处理「已有新版本」的项，顺序执行避免并发解压/复制。
    public func installAllUpdates() async {
        let targets = items.filter { if case .updateAvailable = $0.state { return true } else { return false } }.map(\.id)
        for id in targets {
            await install(id: id)
        }
    }

    // MARK: - 自动检查

    /// 启动时常驻检查 + 周期检查。应用未配置市场地址时直接跳过。
    public func startAutomaticUpdates() {
        autoTask?.cancel()
        guard isConfigured, settings.autoCheckPluginUpdates else { return }

        autoTask = Task { [weak self] in
            // 启动阶段先让插件与 UI 就绪，避免和首屏竞争。
            try? await Task.sleep(for: .seconds(5))
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                if self.settings.autoInstallPluginUpdates {
                    await self.installAllUpdates()
                }
                try? await Task.sleep(for: .seconds(self.automaticInterval))
            }
        }
    }

    public func stopAutomaticUpdates() {
        autoTask?.cancel()
        autoTask = nil
    }
}

private extension PluginUpdateCenter.Status {
    var message: String? {
        if case let .failed(message) = self { return message }
        return nil
    }
}
