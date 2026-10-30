import Foundation
import Observation
import PluginAPI
import SwiftUI

/// 外部插件的安装信息（UI 展示与诊断用）。
public struct ExternalPluginInfo: Equatable, Sendable {
    public let version: String
    public let teamID: String?
    public let installedAt: Date
    public let path: String

    public init(version: String, teamID: String?, installedAt: Date, path: String) {
        self.version = version
        self.teamID = teamID
        self.installedAt = installedAt
        self.path = path
    }
}

public enum PluginSource: Equatable, Sendable {
    case builtIn
    case external(ExternalPluginInfo)
}

/// 外部插件加载器构造出的注册项：清单可在不加载代码时获得，实例按需创建。
public struct ExternalPluginRegistration {
    public let manifest: PluginManifest
    public let info: ExternalPluginInfo
    let makeInstance: @MainActor () throws -> any FeaturePlugin

    public init(
        manifest: PluginManifest,
        info: ExternalPluginInfo,
        makeInstance: @escaping @MainActor () throws -> any FeaturePlugin
    ) {
        self.manifest = manifest
        self.info = info
        self.makeInstance = makeInstance
    }
}

/// 插件生命周期的唯一管理者。
///
/// 状态机（§6.1）：`disabled → missingCapabilities → active`，权限或逐插件授权被收回
/// 都会回到 `missingCapabilities`。启用开关仍然只有一层：启用 / 未启用。
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
        public let source: PluginSource
        /// 已声明但用户尚未授予（或系统尚未授予）的能力。
        public let missingConsent: Set<Capability>

        public var id: String { manifest.id }
        public var isExternal: Bool {
            if case .external = source { return true }
            return false
        }
    }

    private struct Registration {
        let manifest: PluginManifest
        let source: PluginSource
        let makeInstance: @MainActor () throws -> any FeaturePlugin
    }

    @ObservationIgnored private let settings: HostSettings
    @ObservationIgnored private let gate: PermissionGate
    @ObservationIgnored private let consents: PluginConsentStore
    @ObservationIgnored private let inputBus: InputBusCore
    @ObservationIgnored private let hotKeys: HotKeyArbitrator
    @ObservationIgnored private let notifier: NotifierImpl
    @ObservationIgnored private let taskRunner: TaskRunner
    @ObservationIgnored private let logStore: LogStore
    @ObservationIgnored private let hostVersion: String

    private var registrations: [Registration] = []
    private var states: [String: State] = [:]
    private var instances: [String: any FeaturePlugin] = [:]
    private var contexts: [String: PluginContextImpl] = [:]

    public init(
        settings: HostSettings,
        gate: PermissionGate,
        consents: PluginConsentStore,
        inputBus: InputBusCore,
        hotKeys: HotKeyArbitrator,
        notifier: NotifierImpl,
        taskRunner: TaskRunner,
        logStore: LogStore,
        hostVersion: String
    ) {
        self.settings = settings
        self.gate = gate
        self.consents = consents
        self.inputBus = inputBus
        self.hotKeys = hotKeys
        self.notifier = notifier
        self.taskRunner = taskRunner
        self.logStore = logStore
        self.hostVersion = hostVersion

        hotKeys.titleProvider = { [weak self] owner in
            guard let manifest = self?.manifest(of: owner) else { return owner }
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

    // MARK: - 注册

    public func register(_ pluginTypes: [any FeaturePlugin.Type]) {
        let external = registrations.filter { registration in
            if case .external = registration.source { return true } else { return false }
        }
        registrations = pluginTypes.map { type in
            Registration(
                manifest: type.manifest,
                source: .builtIn,
                makeInstance: { type.init() }
            )
        } + external

        for registration in registrations where states[registration.manifest.id] == nil {
            states[registration.manifest.id] = .disabled
        }
    }

    /// 安装/发现外部插件后调用。同 id 视为升级：保留启用状态与配置，重建实例。
    public func registerExternal(_ items: [ExternalPluginRegistration]) {
        for item in items {
            let id = item.manifest.id
            registrations.removeAll { $0.manifest.id == id }
            registrations.append(
                Registration(manifest: item.manifest, source: .external(item.info), makeInstance: item.makeInstance)
            )
            deactivateInstance(id: id)
            contexts.removeValue(forKey: id)
            states[id] = .disabled
            logStore.append(level: .info, pluginID: id, message: "外部插件已登记 v\(item.manifest.version)")
        }
    }

    /// 卸载：先停用并清理，再从注册表移除。
    public func unregister(id: String) {
        deactivateInstance(id: id)
        instances.removeValue(forKey: id)
        contexts.removeValue(forKey: id)
        states.removeValue(forKey: id)
        registrations.removeAll { $0.manifest.id == id }
        settings.enabledPluginIDs.remove(id)
        consents.clear(id)
    }

    // MARK: - 查询

    public var entries: [Entry] {
        registrations.map { registration in
            let manifest = registration.manifest
            return Entry(
                manifest: manifest,
                state: state(of: manifest.id),
                isEnabled: settings.enabledPluginIDs.contains(manifest.id),
                source: registration.source,
                missingConsent: missingConsent(of: manifest.id)
            )
        }
    }

    public var installedCount: Int { registrations.count }

    public var enabledCount: Int {
        registrations.filter { isActive($0.manifest.id) }.count
    }

    public func state(of id: String) -> State {
        states[id] ?? .disabled
    }

    public func isActive(_ id: String) -> Bool {
        state(of: id) == .active
    }

    public func manifest(of id: String) -> PluginManifest? {
        registrations.first { $0.manifest.id == id }?.manifest
    }

    public func source(of id: String) -> PluginSource? {
        registrations.first { $0.manifest.id == id }?.source
    }

    public func makeSettingsView(for id: String) -> AnyView? {
        guard isActive(id), let instance = instances[id] else { return nil }
        return instance.makeSettingsView()
    }

    public func enabledConsumers(of capability: Capability) -> [String] {
        registrations
            .map(\.manifest)
            .filter { manifest in
                settings.enabledPluginIDs.contains(manifest.id)
                    && (manifest.requiredCapabilities.contains(capability) || manifest.optionalCapabilities.contains(capability))
            }
            .map(\.id)
    }

    // MARK: - 逐插件授权

    /// 已生效的授权（清单指纹匹配才算数：插件升级新增能力后必须重新确认）。
    public func grantedConsent(of id: String) -> Set<Capability> {
        guard manifest(of: id) != nil,
              let consent = consents.consent(for: id) else {
            return []
        }
        // 不再用指纹判「整份授权作废」：升级只应让**新增的必需能力**重新确认，
        // 这件事由 missingConsent（declared - granted）与 required 子集判断负责。
        // 这里只把授权裁剪到当前声明范围内，避免残留已移除的能力。
        return consent.granted.intersection(declaredCapabilities(of: id))
    }

    public func declaredCapabilities(of id: String) -> Set<Capability> {
        guard let manifest = manifest(of: id) else { return [] }
        return manifest.requiredCapabilities.union(manifest.optionalCapabilities)
    }

    public func missingConsent(of id: String) -> Set<Capability> {
        declaredCapabilities(of: id).subtracting(grantedConsent(of: id))
    }

    public func needsConsentPrompt(_ id: String) -> Bool {
        guard let manifest = manifest(of: id) else { return false }
        let declared = manifest.requiredCapabilities.union(manifest.optionalCapabilities)
        guard !declared.isEmpty else { return false }
        return !manifest.requiredCapabilities.isSubset(of: grantedConsent(of: id))
    }

    /// 用户确认授权。`required` 必须全部包含，否则拒绝写入（避免「半授权」状态）。
    @discardableResult
    public func grantConsent(_ id: String, capabilities: Set<Capability>) -> Bool {
        guard let manifest = manifest(of: id) else { return false }
        let declared = manifest.requiredCapabilities.union(manifest.optionalCapabilities)
        let sanitized = capabilities.intersection(declared)
        guard manifest.requiredCapabilities.isSubset(of: sanitized) else { return false }

        consents.set(
            PluginConsent(granted: sanitized, manifestFingerprint: PluginConsentStore.fingerprint(manifest: manifest)),
            for: id
        )
        evaluate(id: id)
        logStore.append(level: .info, pluginID: id, message: "插件授权：\(sanitized.map(\.rawValue).sorted().joined(separator: ","))")
        return true
    }

    /// 撤销单项。撤销 required 会立即停用插件（与系统权限被收回的行为一致）。
    public func revokeConsent(_ id: String, capability: Capability) {
        guard let manifest = manifest(of: id) else { return }
        var granted = grantedConsent(of: id)
        granted.remove(capability)
        consents.set(
            PluginConsent(granted: granted, manifestFingerprint: PluginConsentStore.fingerprint(manifest: manifest)),
            for: id
        )
        evaluate(id: id)
        logStore.append(level: .info, pluginID: id, message: "撤销插件授权：\(capability.rawValue)")
    }

    /// 系统授权 + 插件授权的合取。插件侧 `permissions.status` 看到的就是这个结果。
    public func effectiveStatus(_ capability: Capability, for id: String) -> Bool {
        gate.status(of: capability) && grantedConsent(of: id).contains(capability)
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
        for registration in registrations {
            evaluate(id: registration.manifest.id)
        }
    }

    public func deactivateAll() {
        for registration in registrations.reversed() {
            let id = registration.manifest.id
            deactivateInstance(id: id)
            states[id] = .disabled
        }
    }

    public func shutdown() {
        for registration in registrations.reversed() {
            deactivateInstance(id: registration.manifest.id)
        }
    }

    public func reconcile() {
        inputBus.resetAvailability()
        for registration in registrations {
            evaluate(id: registration.manifest.id)
        }
    }

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
        guard let registration = registrations.first(where: { $0.manifest.id == id }) else { return }
        let manifest = registration.manifest

        guard settings.enabledPluginIDs.contains(id) else {
            deactivateInstance(id: id)
            states[id] = .disabled
            return
        }

        // 两层门控：系统授权 + 该插件的用户授权，缺一不可。
        let missing = manifest.requiredCapabilities.filter { !effectiveStatus($0, for: id) }
        if !missing.isEmpty {
            deactivateInstance(id: id)
            states[id] = .missingCapabilities(missing)
            return
        }

        if instances[id] != nil {
            states[id] = .active
            return
        }

        activate(registration: registration, id: id)
    }

    private func activate(registration: Registration, id: String) {
        let context = context(for: registration)

        do {
            let instance = try registration.makeInstance()
            try instance.activate(context: context)
            instances[id] = instance
            states[id] = .active
            logStore.append(level: .info, pluginID: id, message: "插件已激活")
        } catch {
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
            inputBus.cancelAll(owner: id)
            hotKeys.unregisterAll(owner: id)
            notifier.clearOwner(id)
            return
        }
        instance.deactivate()
        inputBus.cancelAll(owner: id)
        hotKeys.unregisterAll(owner: id)
        notifier.clearOwner(id)
        logStore.append(level: .info, pluginID: id, message: "插件已停用")
    }

    private func context(for registration: Registration) -> PluginContextImpl {
        let manifest = registration.manifest
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
            permissions: PluginPermissionFacade(
                gate: gate,
                manifest: manifest,
                granted: grantedConsent(of: manifest.id)
            ),
            notifier: PluginNotifierFacade(impl: notifier, owner: manifest.id),
            logger: PluginLoggerImpl(pluginID: manifest.id, subsystem: AppIdentity.bundleIdentifier, store: logStore),
            runner: taskRunner
        )
        contexts[manifest.id] = context
        return context
    }

    private func handleSourceUnavailable(_ source: InputSource) {
        let capability: Capability = source == .keyboard ? .inputMonitoring : .accessibility
        let subscribers: Set<String> = source == .keyboard
            ? inputBus.keyboardSubscriberIDs
            : inputBus.pointerSubscriberIDs

        for id in subscribers {
            guard settings.enabledPluginIDs.contains(id) else { continue }
            deactivateInstance(id: id)

            // 授权仍在：这只是 tap 超时/重建失败，重试即可。
            // 直接报 missingCapabilities 会表现为「明明有权限却提示缺少权限」。
            if gate.status(of: capability) {
                inputBus.resetAvailability()
                states[id] = .disabled
                evaluate(id: id)
                if isActive(id) {
                    logStore.append(level: .warning, pluginID: id, message: "输入源短暂不可用，已自动恢复：\(source)")
                } else {
                    logStore.append(level: .error, pluginID: id, message: "输入源恢复失败：\(source)")
                }
                continue
            }

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
