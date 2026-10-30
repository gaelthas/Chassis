import Foundation
import Observation
import PluginAPI

/// 插件市场与自动更新。
///
/// 支持多个来源：官方市场来自 Info.plist，用户可追加第三方市场。合并规则：
/// - 按来源顺序取第一个出现的插件 ID（官方在前），后面的同名插件忽略；
/// - 每个来源独立校验自己的签名公钥，互不共享信任；
/// - 任一来源失败不影响其它来源，失败原因汇总到 `lastError`。
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
        /// 该插件来自哪个市场来源（用于 UI 标注与排障）。
        public let sourceID: String
        public var state: ItemState

        public var id: String { plugin.id }
    }

    private let automaticInterval: TimeInterval = 6 * 3600
    private let minimumManualRefreshInterval: TimeInterval = 60

    private let client: MarketplaceClient
    private let installer: PluginInstaller
    private let settings: HostSettings
    private let hostVersion: String
    private let logStore: LogStore

    public var onInstalled: @MainActor () -> Void

    private var index: MarketplaceIndex?
    private var sourceMap: [String: String] = [:]
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

    public var enabledSources: [MarketplaceSource] {
        settings.marketplaceSources.filter { $0.isEnabled && $0.resolvedURL != nil }
    }

    public var isConfigured: Bool {
        !enabledSources.isEmpty
    }

    public var availableUpdateCount: Int {
        items.filter { if case .updateAvailable = $0.state { return true } else { return false } }.count
    }

    public var installableCount: Int {
        items.filter { if case .notInstalled = $0.state { return true } else { return false } }.count
    }

    public func sourceName(of id: String) -> String {
        settings.marketplaceSources.first { $0.id == id }?.name ?? id
    }

    // MARK: - 检查

    public func refreshIfStale() async {
        if let lastChecked, Date().timeIntervalSince(lastChecked) < minimumManualRefreshInterval {
            return
        }
        await refresh()
    }

    public func refresh() async {
        let sources = enabledSources
        guard !sources.isEmpty else {
            status = .failed(MarketplaceError.notConfigured.localizedDescription)
            lastError = status.errorMessage
            return
        }

        status = .checking
        lastError = nil

        var merged: [String: (plugin: MarketplacePlugin, sourceID: String)] = [:]
        var failures: [String] = []

        for source in sources {
            guard let url = source.resolvedURL else { continue }
            do {
                let fetched = try await client.fetchIndex(
                    from: url,
                    publicKeyBase64: source.publicKey.isEmpty ? nil : source.publicKey
                )
                var added = 0
                for plugin in fetched.plugins where merged[plugin.id] == nil {
                    merged[plugin.id] = (plugin, source.id)
                    added += 1
                }
                logStore.append(
                    level: .info,
                    pluginID: "com.gaelthas.chassis:market",
                    message: "市场来源 \(source.name)：\(fetched.plugins.count) 个插件，采纳 \(added) 个"
                )
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                failures.append("\(source.name)：\(message)")
                logStore.append(level: .error, pluginID: "com.gaelthas.chassis:market", message: "来源 \(source.name) 失败：\(message)")
            }
        }

        guard !merged.isEmpty else {
            let message = failures.isEmpty ? "所有市场来源都没有返回插件" : failures.joined(separator: "；")
            status = .failed(message)
            lastError = message
            return
        }

        let combined = MarketplaceIndex(plugins: merged.values.map(\.plugin))
        index = combined
        sourceMap = merged.mapValues(\.sourceID)
        apply(combined)
        lastChecked = Date()
        status = .ready
        if !failures.isEmpty {
            lastError = failures.joined(separator: "；")
        }
        logStore.append(
            level: .info,
            pluginID: "com.gaelthas.chassis:market",
            message: "市场已合并：\(combined.plugins.count) 个插件，\(availableUpdateCount) 个可更新"
        )
    }

    private func apply(_ fetched: MarketplaceIndex) {
        let installed = Dictionary(uniqueKeysWithValues: installer.records.map { ($0.id, $0.version) })
        items = fetched.plugins
            .filter { $0.apiVersion <= 1 }
            .map { plugin in
                let sourceID = sourceMap[plugin.id] ?? MarketplaceSource.officialID
                guard SemanticVersion.isAtLeast(hostVersion, plugin.minHostVersion) else {
                    return Item(plugin: plugin, sourceID: sourceID, state: .incompatible(minimumHostVersion: plugin.minHostVersion))
                }
                guard let installedVersion = installed[plugin.id] else {
                    return Item(plugin: plugin, sourceID: sourceID, state: .notInstalled)
                }
                if SemanticVersion.isAtLeast(installedVersion, plugin.version) {
                    return Item(plugin: plugin, sourceID: sourceID, state: .installed)
                }
                return Item(plugin: plugin, sourceID: sourceID, state: .updateAvailable(installedVersion: installedVersion))
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
                message: "已安装 \(plugin.id) v\(plugin.version)（来源 \(sourceName(of: items[position].sourceID))）"
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

            if let index {
                apply(index)
            }
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            items[position].state = .failed(message)
            logStore.append(level: .error, pluginID: "com.gaelthas.chassis:market", message: "安装 \(plugin.id) 失败：\(message)")
        }
    }

    public func installAllUpdates() async {
        let targets = items.filter { if case .updateAvailable = $0.state { return true } else { return false } }.map(\.id)
        for id in targets {
            await install(id: id)
        }
    }

    // MARK: - 自动检查

    public func startAutomaticUpdates() {
        autoTask?.cancel()
        guard isConfigured, settings.autoCheckPluginUpdates else { return }

        autoTask = Task { [weak self] in
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

    // MARK: - 来源管理

    public func addSource(_ source: MarketplaceSource) {
        guard !settings.marketplaceSources.contains(where: { $0.id == source.id }) else { return }
        settings.marketplaceSources.append(source)
        logStore.append(level: .info, pluginID: "com.gaelthas.chassis:market", message: "新增市场来源：\(source.name)")
    }

    public func removeSource(id: String) {
        settings.marketplaceSources.removeAll { $0.id == id && !$0.isOfficial }
        items.removeAll { $0.sourceID == id }
    }

    public func setSourceEnabled(id: String, enabled: Bool) {
        guard let position = settings.marketplaceSources.firstIndex(where: { $0.id == id }) else { return }
        settings.marketplaceSources[position].isEnabled = enabled
    }
}

private extension PluginUpdateCenter.Status {
    var errorMessage: String? {
        if case let .failed(message) = self { return message }
        return nil
    }
}
