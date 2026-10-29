import AppKit
import AtomicsShim
import CoreGraphics
import Foundation
import PluginAPI

/// 输入总线的唯一实现。
///
/// 三条输入路径（键盘 tap / 鼠标 tap / 指针监听）各自引用计数：
/// 第一个订阅者出现时创建，最后一个订阅者取消时销毁。零订阅者 = 零 tap（§1.1）。
@MainActor
public final class InputBusCore {
    private struct ClickRoute {
        let id: UUID
        let owner: String
        let delivery: DeliveryBox<ClickContext>
    }

    private struct PointerRoute {
        let id: UUID
        let owner: String
        let box: DeliveryBox<CGPoint>
    }

    private struct KeyRoute {
        let id: UUID
        let owner: String
        let filter: KeyFilter
        let syncIntercept: (@Sendable (KeyEvent) -> KeyIntercept)?
        let delivery: DeliveryBox<KeyEvent>
    }

    private struct InterruptionRoute {
        let id: UUID
        let owner: String
        let handler: @MainActor (InputInterruption) -> Void
    }

    private var clickRoutes: [ClickRoute] = []
    private var pointerRoutes: [PointerRoute] = []
    private var keyRoutes: [KeyRoute] = []
    private var interruptionRoutes: [InterruptionRoute] = []

    private let frontmost: FrontmostProcessTracker?
    private let keyboardSlot: OpaquePointer
    private let clickSlot: OpaquePointer
    /// lazy 是为了在初始化完成后仍能安全地 `[weak self]` 捕获。
    private lazy var relay = InterruptionRelay { [weak self] interruption in
        self?.handleInterruption(interruption)
    }

    private var keyboardTap: KeyboardEventTap?
    private var mouseTap: MouseEventTap?
    private var pointerMonitor: PointerMonitor?

    /// 快照在 tap 存活期间不释放：tap 线程只读，绝不在回调里 dealloc。
    private var retainedKeySnapshots: [KeyboardSnapshot] = []
    private var retainedClickSnapshots: [ClickSnapshot] = []

    private(set) var keyboardUnavailable = false
    private(set) var pointerUnavailable = false

    /// 某一路输入降级时通知注册表（如缺权限导致 tap 创建失败），用于驱动 missingCapabilities。
    var onSourceUnavailable: (@MainActor (InputSource) -> Void)?

    public init() {
        guard let keyboardSlot = ch_atomic_ptr_create(nil),
              let clickSlot = ch_atomic_ptr_create(nil) else {
            fatalError("InputBusCore: 无法分配原子指针槽")
        }
        self.keyboardSlot = keyboardSlot
        self.clickSlot = clickSlot
        let frontmost = FrontmostProcessTracker()
        frontmost?.start()
        self.frontmost = frontmost
    }

    // MARK: - 订阅

    func subscribeToClick(owner: String, handler: @escaping @MainActor (ClickContext) -> Void) -> Subscription {
        let id = UUID()
        let box = DeliveryBox<ClickContext>(handler)
        clickRoutes.append(ClickRoute(id: id, owner: owner, delivery: box))
        publishClickSnapshot()
        ensureMouseTap()

        return Subscription { [weak self] in
            box.cancel()
            self?.removeClickRoute(id: id)
        }
    }

    func subscribeToPointerMove(owner: String, handler: @escaping @MainActor (CGPoint) -> Void) -> Subscription {
        let id = UUID()
        let box = DeliveryBox<CGPoint>(handler)
        pointerRoutes.append(PointerRoute(id: id, owner: owner, box: box))
        ensurePointerMonitor()

        return Subscription { [weak self] in
            box.cancel()
            self?.removePointerRoute(id: id)
        }
    }

    func subscribeToKey(
        owner: String,
        filter: KeyFilter,
        syncIntercept: (@Sendable (KeyEvent) -> KeyIntercept)?,
        handler: @escaping @MainActor (KeyEvent) -> Void
    ) -> Subscription {
        let id = UUID()
        let box = DeliveryBox<KeyEvent>(handler)
        keyRoutes.append(
            KeyRoute(id: id, owner: owner, filter: filter, syncIntercept: syncIntercept, delivery: box)
        )
        publishKeySnapshot()
        ensureKeyboardTap()

        return Subscription { [weak self] in
            box.cancel()
            self?.removeKeyRoute(id: id)
        }
    }

    func subscribeToInterruptions(owner: String, handler: @escaping @MainActor (InputInterruption) -> Void) -> Subscription {
        let id = UUID()
        interruptionRoutes.append(InterruptionRoute(id: id, owner: owner, handler: handler))
        return Subscription { [weak self] in
            self?.interruptionRoutes.removeAll { $0.id == id }
        }
    }

    /// 强制清理：`deactivate()` 返回后基座必须调用，无论插件是否主动 cancel。
    /// 漏掉这一步会让引用计数永不归零，空载承诺被静默破坏（§6.3）。
    func cancelAll(owner: String) {
        for route in clickRoutes where route.owner == owner {
            route.delivery.cancel()
        }
        for route in pointerRoutes where route.owner == owner {
            route.box.cancel()
        }
        for route in keyRoutes where route.owner == owner {
            route.delivery.cancel()
        }
        clickRoutes.removeAll { $0.owner == owner }
        pointerRoutes.removeAll { $0.owner == owner }
        keyRoutes.removeAll { $0.owner == owner }
        interruptionRoutes.removeAll { $0.owner == owner }

        publishClickSnapshot()
        publishKeySnapshot()
        reconcileTapLifetime()
    }

    // MARK: - 查询（注册表与诊断用）

    var keyboardSubscriberIDs: Set<String> { Set(keyRoutes.map(\.owner)) }
    var pointerSubscriberIDs: Set<String> { Set(clickRoutes.map(\.owner)).union(pointerRoutes.map(\.owner)) }
    public var hasKeyboardTap: Bool { keyboardTap?.isRunning ?? false }
    public var hasMouseTap: Bool { mouseTap != nil }
    public var hasPointerMonitor: Bool { pointerMonitor?.isRunning ?? false }
    public var activeTapCount: Int {
        [hasKeyboardTap, hasMouseTap, hasPointerMonitor].filter { $0 }.count
    }

    /// 权限恢复后允许重新尝试创建。
    func resetAvailability() {
        keyboardUnavailable = false
        pointerUnavailable = false
        if !clickRoutes.isEmpty { ensureMouseTap() }
        if !pointerRoutes.isEmpty { ensurePointerMonitor() }
        if !keyRoutes.isEmpty { ensureKeyboardTap() }
    }

    // MARK: - 生命周期

    private func reconcileTapLifetime() {
        if clickRoutes.isEmpty {
            mouseTap?.stop()
            mouseTap = nil
        }
        if pointerRoutes.isEmpty {
            pointerMonitor?.stop()
            pointerMonitor = nil
        }
        if keyRoutes.isEmpty {
            keyboardTap?.stop()
            keyboardTap = nil
        }
    }

    private func ensureKeyboardTap() {
        guard !keyRoutes.isEmpty else { return }
        if keyboardTap != nil { return }
        guard !keyboardUnavailable else { return }

        guard let frontmost else {
            keyboardUnavailable = true
            broadcast(InputInterruption(source: .keyboard, reason: .tapCreationFailed, recovered: false))
            return
        }

        let tap = KeyboardEventTap(snapshotSlot: keyboardSlot, frontmostSlot: frontmost.slot, relay: relay)
        keyboardTap = tap
        tap.start { [weak self] success in
            guard let self, !success else { return }
            self.keyboardUnavailable = true
            self.keyboardTap = nil
            self.onSourceUnavailable?(.keyboard)
        }
    }

    private func ensureMouseTap() {
        guard !clickRoutes.isEmpty else { return }
        if mouseTap != nil { return }
        guard !pointerUnavailable else { return }

        guard let frontmost else {
            pointerUnavailable = true
            broadcast(InputInterruption(source: .pointer, reason: .tapCreationFailed, recovered: false))
            return
        }

        let tap = MouseEventTap(snapshotSlot: clickSlot, frontmostSlot: frontmost.slot, relay: relay)
        mouseTap = tap
        tap.start { [weak self] success in
            guard let self, !success else { return }
            self.pointerUnavailable = true
            self.mouseTap = nil
            self.onSourceUnavailable?(.pointer)
        }
    }

    private func ensurePointerMonitor() {
        guard !pointerRoutes.isEmpty else { return }
        if pointerMonitor != nil { return }
        guard !pointerUnavailable else { return }

        let monitor = PointerMonitor { [weak self] point in
            self?.deliverPointer(point)
        }
        pointerMonitor = monitor
        if !monitor.start() {
            pointerMonitor = nil
            pointerUnavailable = true
            broadcast(InputInterruption(source: .pointer, reason: .tapCreationFailed, recovered: false))
            onSourceUnavailable?(.pointer)
        }
    }

    private func deliverPointer(_ point: CGPoint) {
        for route in pointerRoutes {
            route.box.dispatch(point)
        }
    }

    // MARK: - 路由

    private func removeClickRoute(id: UUID) {
        clickRoutes.removeAll { $0.id == id }
        publishClickSnapshot()
        if clickRoutes.isEmpty {
            mouseTap?.stop()
            mouseTap = nil
        }
    }

    private func removePointerRoute(id: UUID) {
        pointerRoutes.removeAll { $0.id == id }
        if pointerRoutes.isEmpty {
            pointerMonitor?.stop()
            pointerMonitor = nil
        }
    }

    private func removeKeyRoute(id: UUID) {
        keyRoutes.removeAll { $0.id == id }
        publishKeySnapshot()
        if keyRoutes.isEmpty {
            keyboardTap?.stop()
            keyboardTap = nil
        }
    }

    private func handleInterruption(_ interruption: InputInterruption) {
        // 保留订阅：插件需要在下一轮里自己决定是清理会话还是等恢复。
        for route in interruptionRoutes {
            route.handler(interruption)
        }
        if !interruption.recovered {
            onSourceUnavailable?(interruption.source)
        }
    }

    private func broadcast(_ interruption: InputInterruption) {
        for route in interruptionRoutes {
            route.handler(interruption)
        }
    }

    // MARK: - 快照发布

    private func publishKeySnapshot() {
        let routes = keyRoutes.map { route in
            KeyboardSnapshot.Route(
                keyCodes: route.filter.keyCodes,
                requiredFlags: route.filter.requiredFlags,
                syncIntercept: route.syncIntercept,
                delivery: route.delivery
            )
        }
        let snapshot = KeyboardSnapshot(routes: routes)
        // 先持有引用（retain），再把裸指针发布给 tap 线程；tap 存活期间永不释放。
        retainedKeySnapshots.append(snapshot)
        let pointer = Unmanaged.passUnretained(snapshot).toOpaque()
        _ = ch_atomic_ptr_exchange(keyboardSlot, pointer)
        trimKeySnapshotsIfIdle()
    }

    private func publishClickSnapshot() {
        let routes = clickRoutes.map { ClickSnapshot.Route(delivery: $0.delivery) }
        let snapshot = ClickSnapshot(routes: routes)
        retainedClickSnapshots.append(snapshot)
        let pointer = Unmanaged.passUnretained(snapshot).toOpaque()
        _ = ch_atomic_ptr_exchange(clickSlot, pointer)
        trimClickSnapshotsIfIdle()
    }

    /// tap 停了才允许释放旧快照：tap 线程可能正持有其中任意一份。
    private func trimKeySnapshotsIfIdle() {
        guard keyboardTap == nil else { return }
        if retainedKeySnapshots.count > 2 {
            retainedKeySnapshots.removeFirst(retainedKeySnapshots.count - 2)
        }
    }

    private func trimClickSnapshotsIfIdle() {
        guard mouseTap == nil else { return }
        if retainedClickSnapshots.count > 2 {
            retainedClickSnapshots.removeFirst(retainedClickSnapshots.count - 2)
        }
    }
}
