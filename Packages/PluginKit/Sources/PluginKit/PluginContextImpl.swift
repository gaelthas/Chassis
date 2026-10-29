import CoreGraphics
import Foundation
import PluginAPI

/// 基座交给插件的 context。同一插件实例在 enabled 期间拿到的是同一个 context；
/// `deactivate` 之后基座不再向它路由任何回调，但调用不会崩溃（§5.3）。
@MainActor
final class PluginContextImpl: PluginContext {
    let pluginID: String
    let hostVersion: String
    let store: PluginStore
    let inputBus: InputBus
    let hotKeys: HotKeyService
    let permissions: PermissionService
    let notifier: Notifier
    let logger: PluginLogger

    private let runner: TaskRunner

    init(
        pluginID: String,
        hostVersion: String,
        store: PluginStore,
        inputBus: InputBus,
        hotKeys: HotKeyService,
        permissions: PermissionService,
        notifier: Notifier,
        logger: PluginLogger,
        runner: TaskRunner
    ) {
        self.pluginID = pluginID
        self.hostVersion = hostVersion
        self.store = store
        self.inputBus = inputBus
        self.hotKeys = hotKeys
        self.permissions = permissions
        self.notifier = notifier
        self.logger = logger
        self.runner = runner
    }

    func performBackground<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await runner.perform(work)
    }
}

// MARK: - 门面

/// 输入总线门面：把 owner 打在订阅上，让基座能按插件强制清理。
@MainActor
final class PluginInputBusFacade: InputBus {
    private let core: InputBusCore
    private let owner: String

    init(core: InputBusCore, owner: String) {
        self.core = core
        self.owner = owner
    }

    func subscribeToClick(_ handler: @escaping @MainActor (ClickContext) -> Void) -> Subscription {
        core.subscribeToClick(owner: owner, handler: handler)
    }

    func subscribeToPointerMove(_ handler: @escaping @MainActor (CGPoint) -> Void) -> Subscription {
        core.subscribeToPointerMove(owner: owner, handler: handler)
    }

    func subscribeToKey(
        _ filter: KeyFilter,
        syncIntercept: (@Sendable (KeyEvent) -> KeyIntercept)?,
        handler: @escaping @MainActor (KeyEvent) -> Void
    ) -> Subscription {
        core.subscribeToKey(owner: owner, filter: filter, syncIntercept: syncIntercept, handler: handler)
    }

    func subscribeToInterruptions(_ handler: @escaping @MainActor (InputInterruption) -> Void) -> Subscription {
        core.subscribeToInterruptions(owner: owner, handler: handler)
    }
}

/// 快捷键门面：插件不需要（也不应该）传 pluginID。
@MainActor
final class PluginHotKeyFacade: HotKeyService {
    private let arbitrator: HotKeyArbitrator
    private let owner: String

    init(arbitrator: HotKeyArbitrator, owner: String) {
        self.arbitrator = arbitrator
        self.owner = owner
    }

    func register(_ spec: HotKeySpec, handler: @escaping @MainActor () -> Void) throws {
        try arbitrator.register(spec, owner: owner, handler: handler)
    }

    func update(_ spec: HotKeySpec) throws {
        try arbitrator.update(owner: owner, to: spec)
    }

    func availability(of spec: HotKeySpec) -> HotKeyAvailability {
        arbitrator.availability(of: spec, requester: owner)
    }

    func unregister() {
        arbitrator.unregisterAll(owner: owner)
    }
}

/// 权限门面：`missing` 只统计本插件声明过的能力。
@MainActor
final class PluginPermissionFacade: PermissionService {
    private let gate: PermissionGate
    private let declared: Set<Capability>

    init(gate: PermissionGate, manifest: PluginManifest) {
        self.gate = gate
        self.declared = manifest.requiredCapabilities.union(manifest.optionalCapabilities)
    }

    func status(of capability: Capability) -> Bool {
        gate.status(of: capability)
    }

    func isRestricted(_ capability: Capability) -> Bool {
        gate.isRestricted(capability)
    }

    var missing: Set<Capability> {
        declared.filter { !gate.status(of: $0) }
    }

    func request(_ capability: Capability) {
        gate.request(capability)
    }
}

/// 通知门面：给每一次投递打上 owner，便于节流统计与点击路由。
@MainActor
final class PluginNotifierFacade: Notifier {
    private let impl: NotifierImpl
    private let owner: String

    init(impl: NotifierImpl, owner: String) {
        self.impl = impl
        self.owner = owner
    }

    var authorization: NotificationAuthorization { impl.authorization }

    func requestAuthorization() async -> Bool {
        await impl.requestAuthorization()
    }

    func post(_ notification: PluginNotification) {
        impl.post(notification, owner: owner)
    }
}
