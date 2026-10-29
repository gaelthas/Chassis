import Foundation
import Observation
import PluginAPI
import SwiftUI

/// 插件生命周期的唯一管理者。
///
/// 状态机（§6.1）：`disabled → missingCapabilities → active`，`active` 因权限收回回到
/// `missingCapabilities`，`activate` 抛错进 `failed`。开关只有一层：启用 / 未启用。
@MainActor
@Observable
public final class PluginRegistry {
    public enum State: Equatable {
        case disabled
        case missingCapabilities(Set<Capability>)
        case active
        case failed(String)
    }

    public struct Entry: Identifiable {
        public let manifest: PluginManifest
        public let state: State
        public let isEnabled: Bool

        public var id: String { manifest.id }
    }

    @ObservationIgnored private let settings: HostSettings
    @ObservationIgnored private let gate: PermissionGate
    @ObservationIgnored private let inputBus: InputBusCore
    @ObservationIgnored private let hotKeys: HotKeyArbitrator
    @ObservationIgnored private let notifier: NotifierImpl
    @ObservationIgnored private let taskRunner: TaskRunner
    @ObservationIgnored private let logStore: LogStore
    @ObservationIgnored private let hostVersion: String

    private var types: [any FeaturePlugin.Type] = []
    private var manifests: [PluginManifest] = []
    private var states: [String: State] = [:]
    private var instances: [String: any FeaturePlugin] = [:]
    private var contexts: [String: PluginContextImpl] = [:]

    public init(
        settings: HostSettings,
        gate: PermissionGate,
        inputBus: InputBusCore,
        hotKeys: HotKeyArbitrator,
        notifier: NotifierImpl,
        taskRunner: TaskRunner,
        logStore: LogStore,
        hostVersion: String
    ) {
        self.settings = settings
        self.gate = gate
        self.inputBus = inputBus
        self.hotKeys = hotKeys
        self.notifier = notifier
        self.taskRunner = taskRunner
        self.logStore = logStore
        self.hostVersion = hostVersion

        hotKeys.titleProvider = { [weak self] owner in
            guard let manifest = self?.manifests.first(where: { $0.id == owner }) else { return owner }
            return manifest.localizedTitle ?? owner
        }
        notifier.isPluginActive = { [weak self] owner in
            self?.isActive(owner) ?? false
        }
        gate.consumersProvider = { [weak self] capability in
            self?.enabledConsumers(of: capability) ?? []
        }
        inputBus.onSourceUnavailable = { [weak self] source in
            self?.handleSourceUnavailable(source)
        }
    }

    // MARK: - 注册与查询

    public func register(_ pluginTypes: [any FeaturePlugin.Type]) {
        types = pluginTypes
        manifests = pluginTypes.map { $0.manifest }
        for manifest in manifests where states[manifest.id] == nil {
            states[manifest.id] = .disabled
        }
    }

    public var entries: [Entry] {
        manifests.map { manifest in
            Entry(
                manifest: manifest,
                state: state(of: manifest.id),
                isEnabled: settings.enabledPluginIDs.contains(manifest.id)
            )
        }
    }

    public var installedCount: Int { manifests.count }

    public var enabledCount: Int {
        manifests.filter { isActive($0.id) }.count
    }

    public func state(of id: String) -> State {
        states[id] ?? .disabled
    }

    public func isActive(_ id: String) -> Bool {
        state(of: id) == .active
    }

    public func manifest(of id: String) -> PluginManifest? {
        manifests.first { $0.id == id }
    }

    /// 插件设置视图只在 active 时构建：半初始化或权限缺失时构建极易触发插件内部的隐式假设（§6.6）。
    public func makeSettingsView(for id: String) -> AnyView? {
        guard isActive(id), let instance = instances[id] else { return nil }
        return instance.makeSettingsView()
    }

    public func enabledConsumers(of capability: Capability) -> [String] {
        manifests.filter { manifest in
            settings.enabledPluginIDs.contains(manifest.id)
                && (manifest.requiredCapabilities.contains(capability) || manifest.optionalCapabilities.contains(capability))
        }
        .map(\.id)
    }

    // MARK: - 启停

    public func setEnabled(_ id: String, enabled: Bool) {
        if enabled {
            settings.enabledPluginIDs.insert(id)
        } else {
            settings.enabledPluginIDs.remove(id)
        }
        evaluate(id: id)
    }

    public func activateAll() {
        for type in types {
            evaluate(id: type.manifest.id)
        }
    }

    /// 按注册逆序关闭。
    public func deactivateAll() {
        for type in types.reversed() {
            let id = type.manifest.id
            deactivateInstance(id: id)
            states[id] = .disabled
        }
    }

    public func shutdown() {
        for type in types.reversed() {
            deactivateInstance(id: type.manifest.id)
        }
    }

    /// 权限变化后的重判定。由 `didBecomeActive` 与权限页驱动，不重启进程。
    public func reconcile() {
        inputBus.resetAvailability()
        for type in types {
            evaluate(id: type.manifest.id)
        }
    }

    /// 用户点「重试」：不做失败缓存，重新按能力判定（§6.1 迁移表）。
    public func retry(_ id: String) {
        states[id] = .disabled
        evaluate(id: id)
    }

    public func resetConfiguration(for id: String) {
        contexts[id]?.store.removeAll()
        logStore.append(level: .info, pluginID: id, message: "插件配置已重置")
    }

    // MARK: - 状态机

    private func evaluate(id: String) {
        guard let type = types.first(where: { $0.manifest.id == id }) else { return }

        guard settings.enabledPluginIDs.contains(id) else {
            deactivateInstance(id: id)
            states[id] = .disabled
            return
        }

        let missing = type.manifest.requiredCapabilities.filter { !gate.status(of: $0) }
        if !missing.isEmpty {
            deactivateInstance(id: id)
            states[id] = .missingCapabilities(missing)
            return
        }

        if instances[id] != nil {
            states[id] = .active
            return
        }

        activate(type: type, id: id)
    }

    private func activate(type: any FeaturePlugin.Type, id: String) {
        let context = context(for: type)

        do {
            let instance = type.init()
            try instance.activate(context: context)
            instances[id] = instance
            states[id] = .active
            logStore.append(level: .info, pluginID: id, message: "插件已激活")
        } catch {
            // 单个插件 activate 抛错只影响自己（§6.1）。
            cleanupAfterFailedActivation(id: id)
            states[id] = .failed(String(describing: error))
            logStore.append(level: .error, pluginID: id, message: "激活失败：\(error)")
        }
    }

    private func cleanupAfterFailedActivation(id: String) {
        instances[id] = nil
        inputBus.cancelAll(owner: id)
        hotKeys.unregisterAll(owner: id)
        notifier.clearOwner(id)
    }

    private func deactivateInstance(id: String) {
        guard let instance = instances.removeValue(forKey: id) else {
            // 即使没有实例也要清理，防止上次 activate 中途失败留下的订阅。
            inputBus.cancelAll(owner: id)
            hotKeys.unregisterAll(owner: id)
            notifier.clearOwner(id)
            return
        }
        instance.deactivate()
        // 强制清理：插件忘记 cancel 也不会泄漏（§6.3）。
        inputBus.cancelAll(owner: id)
        hotKeys.unregisterAll(owner: id)
        notifier.clearOwner(id)
        logStore.append(level: .info, pluginID: id, message: "插件已停用")
    }

    private func context(for type: any FeaturePlugin.Type) -> PluginContextImpl {
        let manifest = type.manifest
        if let cached = contexts[manifest.id] {
            return cached
        }

        guard let store = PluginStoreImpl(pluginID: manifest.id) else {
            fatalError("无法为 \(manifest.id) 创建配置 suite")
        }

        let context = PluginContextImpl(
            pluginID: manifest.id,
            hostVersion: hostVersion,
            store: store,
            inputBus: PluginInputBusFacade(core: inputBus, owner: manifest.id),
            hotKeys: PluginHotKeyFacade(arbitrator: hotKeys, owner: manifest.id),
            permissions: PluginPermissionFacade(gate: gate, manifest: manifest),
            notifier: PluginNotifierFacade(impl: notifier, owner: manifest.id),
            logger: PluginLoggerImpl(pluginID: manifest.id, subsystem: AppIdentity.bundleIdentifier, store: logStore),
            runner: taskRunner
        )
        contexts[manifest.id] = context
        return context
    }

    /// 输入源创建失败（通常是缺权限）：订阅了该路的插件迁到 missingCapabilities。
    private func handleSourceUnavailable(_ source: InputSource) {
        let capability: Capability = source == .keyboard ? .inputMonitoring : .accessibility
        let subscribers: Set<String> = source == .keyboard
            ? inputBus.keyboardSubscriberIDs
            : inputBus.pointerSubscriberIDs

        for id in subscribers {
            guard settings.enabledPluginIDs.contains(id) else { continue }
            deactivateInstance(id: id)
            let already = states[id]
            var missing: Set<Capability> = [capability]
            if case let .missingCapabilities(existing) = already {
                missing.formUnion(existing)
            }
            states[id] = .missingCapabilities(missing)
            logStore.append(level: .warning, pluginID: id, message: "输入源不可用，已降级：\(source)")
        }
    }
}
