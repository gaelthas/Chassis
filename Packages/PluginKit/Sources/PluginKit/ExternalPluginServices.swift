import AppKit
import Foundation
import PluginABI
import PluginAPI

/// 外部插件与基座之间唯一的运行期桥：持有插件 context，并负责回收所有订阅。
///
/// 约定：`click / pointer / key.handler / interruption / hotkey / notification / store / log`
/// 的回调都在主线程；只有 `key.intercept` 在 tap 线程，绝不能进入 Main Actor。
final class ExternalServicesBox: @unchecked Sendable {
    let context: PluginContext
    let pluginIDPointer: UnsafeMutablePointer<CChar>
    let hostVersionPointer: UnsafeMutablePointer<CChar>

    private let backgroundQueue = DispatchQueue(label: "com.gaelthas.chassis.external.background")
    private var subscriptions: [Subscription] = []

    init(pluginID: String, hostVersion: String, context: PluginContext) {
        self.context = context
        self.pluginIDPointer = strdup(pluginID) ?? UnsafeMutablePointer<CChar>.allocate(capacity: 1)
        self.hostVersionPointer = strdup(hostVersion) ?? UnsafeMutablePointer<CChar>.allocate(capacity: 1)
    }

    deinit {
        free(pluginIDPointer)
        free(hostVersionPointer)
    }

    func add(_ subscription: Subscription) {
        subscriptions.append(subscription)
    }

    @MainActor
    func cancelAll() {
        for subscription in subscriptions {
            subscription.cancel()
        }
        subscriptions.removeAll()
    }

    func performBackground(_ work: () -> Void) {
        backgroundQueue.sync(execute: work)
    }
}

/// Swift 6 的 `assumeIsolated` 视闭包为 `@Sendable`，裸指针不能直接捕获；
/// 用只读载体把它们带进主线程，避免在每个回调里散落 `unsafeBitCast`。
private struct RawPointer: @unchecked Sendable {
    let value: UnsafeMutableRawPointer?

    init(_ value: UnsafeMutableRawPointer?) {
        self.value = value
    }
}

private final class PointerSlot: @unchecked Sendable {
    var raw: UnsafeRawPointer?
}

private struct BufferPointer: @unchecked Sendable {
    let value: UnsafeMutablePointer<CChar>?
    let size: Int
}

/// 把基座服务包装成 C 函数指针表。所有函数都不能捕获上下文，因此全部是顶层函数。
enum ExternalServicesFactory {
    static func make(box: ExternalServicesBox) -> chassis_host_services_v1 {
        chassis_host_services_v1(
            struct_size: UInt32(MemoryLayout<chassis_host_services_v1>.size),
            host: Unmanaged.passUnretained(box).toOpaque(),
            plugin_id: chPluginID,
            host_version: chHostVersion,
            permission_status: chPermissionStatus,
            subscribe_click: chSubscribeClick,
            subscribe_pointer: chSubscribePointer,
            subscribe_key: chSubscribeKey,
            subscribe_interruptions: chSubscribeInterruptions,
            unsubscribe: chUnsubscribe,
            register_hotkey: chRegisterHotKey,
            unregister_hotkeys: chUnregisterHotKeys,
            post_notification: chPostNotification,
            store_get: chStoreGet,
            store_set: chStoreSet,
            log: chLog,
            perform_background: chPerformBackground
        )
    }
}

// MARK: - 基础查询

private func box(_ host: UnsafeMutableRawPointer?) -> ExternalServicesBox? {
    guard let host else { return nil }
    return Unmanaged<ExternalServicesBox>.fromOpaque(host).takeUnretainedValue()
}

private func chPluginID(_ host: UnsafeMutableRawPointer?) -> UnsafePointer<CChar>? {
    box(host).map { UnsafePointer($0.pluginIDPointer) }
}

private func chHostVersion(_ host: UnsafeMutableRawPointer?) -> UnsafePointer<CChar>? {
    box(host).map { UnsafePointer($0.hostVersionPointer) }
}

private func chPermissionStatus(_ host: UnsafeMutableRawPointer?, _ capability: UnsafePointer<CChar>?) -> Int32 {
    guard let box = box(host), let capability else { return 0 }
    let name = String(cString: capability)
    guard let parsed = Capability(rawValue: name) else { return 0 }
    return MainActor.assumeIsolated {
        box.context.permissions.status(of: parsed) ? 1 : 0
    }
}

// MARK: - 订阅

private func retain(_ subscription: Subscription, in box: ExternalServicesBox) -> UnsafeRawPointer {
    box.add(subscription)
    return UnsafeRawPointer(Unmanaged.passRetained(subscription).toOpaque())
}

private func chSubscribeClick(
    _ host: UnsafeMutableRawPointer?,
    _ callback: (@convention(c) (UnsafeMutableRawPointer?, UnsafePointer<chassis_click_v1>?) -> Void)?,
    _ ctx: UnsafeMutableRawPointer?
) -> UnsafeRawPointer? {
    guard let box = box(host), let callback else { return nil }
    let context = RawPointer(ctx)
    let slot = PointerSlot()

    MainActor.assumeIsolated {
        let subscription = box.context.inputBus.subscribeToClick { click in
            var event = chassis_click_v1(
                x: Double(click.location.x),
                y: Double(click.location.y),
                timestamp: click.timestamp,
                button: {
                    switch click.button {
                    case .left: return Int32(0)
                    case .right: return Int32(1)
                    case .other: return Int32(2)
                    }
                }(),
                click_count: Int32(click.clickCount),
                frontmost_pid: click.frontmostPID ?? 0
            )
            callback(context.value, &event)
        }
        slot.raw = retain(subscription, in: box)
    }
    return slot.raw
}

private func chSubscribePointer(
    _ host: UnsafeMutableRawPointer?,
    _ callback: (@convention(c) (UnsafeMutableRawPointer?, Double, Double) -> Void)?,
    _ ctx: UnsafeMutableRawPointer?
) -> UnsafeRawPointer? {
    guard let box = box(host), let callback else { return nil }
    let context = RawPointer(ctx)
    let slot = PointerSlot()

    MainActor.assumeIsolated {
        let subscription = box.context.inputBus.subscribeToPointerMove { point in
            callback(context.value, Double(point.x), Double(point.y))
        }
        slot.raw = retain(subscription, in: box)
    }
    return slot.raw
}

/// tap 线程上使用的最小载荷：函数指针 + ctx 必须显式装箱，否则 Swift 6 不允许捕获。
private final class KeyCallbacks: @unchecked Sendable {
    let intercept: (@convention(c) (UnsafeMutableRawPointer?, UnsafePointer<chassis_key_v1>?) -> Int32)?
    let handler: (@convention(c) (UnsafeMutableRawPointer?, UnsafePointer<chassis_key_v1>?) -> Void)?
    let ctx: UnsafeMutableRawPointer?

    init(
        intercept: (@convention(c) (UnsafeMutableRawPointer?, UnsafePointer<chassis_key_v1>?) -> Int32)?,
        handler: (@convention(c) (UnsafeMutableRawPointer?, UnsafePointer<chassis_key_v1>?) -> Void)?,
        ctx: UnsafeMutableRawPointer?
    ) {
        self.intercept = intercept
        self.handler = handler
        self.ctx = ctx
    }

    func event(_ event: KeyEvent) -> chassis_key_v1 {
        let kind: Int32
        switch event.kind {
        case .keyDown: kind = 0
        case .keyUp: kind = 1
        case .flagsChanged: kind = 2
        }
        return chassis_key_v1(
            kind: kind,
            key_code: event.keyCode,
            flags: event.flags.rawValue,
            is_repeat: event.isRepeat ? 1 : 0
        )
    }
}

private func chSubscribeKey(
    _ host: UnsafeMutableRawPointer?,
    _ keyCodes: UnsafePointer<Int64>?,
    _ count: Int,
    _ requiredFlags: UInt64,
    _ intercept: (@convention(c) (UnsafeMutableRawPointer?, UnsafePointer<chassis_key_v1>?) -> Int32)?,
    _ handler: (@convention(c) (UnsafeMutableRawPointer?, UnsafePointer<chassis_key_v1>?) -> Void)?,
    _ ctx: UnsafeMutableRawPointer?
) -> UnsafeRawPointer? {
    guard let box = box(host), let keyCodes, count > 0 else { return nil }
    let codes = Set((0..<count).map { keyCodes[$0] })
    let filter = KeyFilter(keyCodes: codes, requiredFlags: CGEventFlags(rawValue: requiredFlags))
    let callbacks = KeyCallbacks(intercept: intercept, handler: handler, ctx: ctx)
    let slot = PointerSlot()

    // 显式参数类型，避免「可选 + 闭包」的推断歧义。
    var interceptor: (@Sendable (KeyEvent) -> KeyIntercept)?
    if intercept != nil {
        interceptor = { (event: KeyEvent) -> KeyIntercept in
            // tap 线程：只调用 C 函数指针，不碰 Main Actor。
            var payload = callbacks.event(event)
            return (callbacks.intercept?(callbacks.ctx, &payload) ?? 0) != 0 ? .consume : .passthrough
        }
    }

    MainActor.assumeIsolated {
        let subscription = box.context.inputBus.subscribeToKey(
            filter,
            syncIntercept: interceptor,
            handler: { event in
                guard let handler = callbacks.handler else { return }
                var payload = callbacks.event(event)
                handler(callbacks.ctx, &payload)
            }
        )
        slot.raw = retain(subscription, in: box)
    }
    return slot.raw
}

private func chSubscribeInterruptions(
    _ host: UnsafeMutableRawPointer?,
    _ callback: (@convention(c) (UnsafeMutableRawPointer?, Int32, Int32, Int32) -> Void)?,
    _ ctx: UnsafeMutableRawPointer?
) -> UnsafeRawPointer? {
    guard let box = box(host), let callback else { return nil }
    let context = RawPointer(ctx)
    let slot = PointerSlot()

    MainActor.assumeIsolated {
        let subscription = box.context.inputBus.subscribeToInterruptions { interruption in
            let source: Int32 = interruption.source == .keyboard ? 0 : 1
            let reason: Int32
            switch interruption.reason {
            case .timeoutDisabled: reason = 0
            case .permissionRevoked: reason = 1
            case .tapCreationFailed: reason = 2
            }
            callback(context.value, source, reason, interruption.recovered ? 1 : 0)
        }
        slot.raw = retain(subscription, in: box)
    }
    return slot.raw
}

private func chUnsubscribe(_ host: UnsafeMutableRawPointer?, _ subscription: UnsafeRawPointer?) {
    guard let subscription else { return }
    let slot = PointerSlot()
    slot.raw = subscription
    MainActor.assumeIsolated {
        guard let raw = slot.raw else { return }
        let value = Unmanaged<Subscription>.fromOpaque(UnsafeMutableRawPointer(mutating: raw)).takeRetainedValue()
        value.cancel()
    }
}

// MARK: - 快捷键

private final class HotKeyCallback: @unchecked Sendable {
    let callback: @convention(c) (UnsafeMutableRawPointer?) -> Void
    let ctx: UnsafeMutableRawPointer?

    init(callback: @escaping @convention(c) (UnsafeMutableRawPointer?) -> Void, ctx: UnsafeMutableRawPointer?) {
        self.callback = callback
        self.ctx = ctx
    }
}

private func chRegisterHotKey(
    _ host: UnsafeMutableRawPointer?,
    _ keyCode: UInt32,
    _ modifiers: UInt32,
    _ callback: (@convention(c) (UnsafeMutableRawPointer?) -> Void)?,
    _ ctx: UnsafeMutableRawPointer?
) -> Int32 {
    guard let box = box(host), let callback else { return -1 }
    let wrapper = HotKeyCallback(callback: callback, ctx: ctx)

    return MainActor.assumeIsolated {
        do {
            try box.context.hotKeys.register(
                HotKeySpec(keyCode: keyCode, modifiers: HotKeyModifiers(rawValue: modifiers))
            ) {
                wrapper.callback(wrapper.ctx)
            }
            return Int32(0)
        } catch {
            return Int32(-2)
        }
    }
}

private func chUnregisterHotKeys(_ host: UnsafeMutableRawPointer?) {
    guard let box = box(host) else { return }
    MainActor.assumeIsolated { box.context.hotKeys.unregister() }
}

// MARK: - 通知 / 存储 / 日志 / 后台

private func chPostNotification(
    _ host: UnsafeMutableRawPointer?,
    _ identifier: UnsafePointer<CChar>?,
    _ title: UnsafePointer<CChar>?,
    _ body: UnsafePointer<CChar>?
) {
    guard let box = box(host) else { return }
    let id = identifier.map(String.init(cString:)) ?? "default"
    let titleText = title.map(String.init(cString:)) ?? ""
    let bodyText = body.map(String.init(cString:)) ?? ""

    MainActor.assumeIsolated {
        box.context.notifier.post(
            PluginNotification(id: id, title: titleText, body: bodyText, priority: .normal)
        )
    }
}

private func chStoreGet(
    _ host: UnsafeMutableRawPointer?,
    _ key: UnsafePointer<CChar>?,
    _ buffer: UnsafeMutablePointer<CChar>?,
    _ bufferSize: Int
) -> Int32 {
    guard let box = box(host), let key else { return -1 }
    let keyText = String(cString: key)
    let output = BufferPointer(value: buffer, size: bufferSize)

    return MainActor.assumeIsolated {
        guard let value = box.context.store.value(String.self, forKey: keyText) else { return Int32(-1) }
        let utf8 = Array(value.utf8)
        guard let buffer = output.value, output.size > utf8.count else { return Int32(utf8.count + 1) }
        for (index, byte) in utf8.enumerated() {
            buffer[index] = CChar(bitPattern: byte)
        }
        buffer[utf8.count] = 0
        return Int32(utf8.count)
    }
}

private func chStoreSet(_ host: UnsafeMutableRawPointer?, _ key: UnsafePointer<CChar>?, _ value: UnsafePointer<CChar>?) {
    guard let box = box(host), let key else { return }
    let keyText = String(cString: key)
    let valueText = value.map(String.init(cString:)) ?? ""
    MainActor.assumeIsolated {
        box.context.store.set(valueText, forKey: keyText)
    }
}

private func chLog(_ host: UnsafeMutableRawPointer?, _ level: Int32, _ message: UnsafePointer<CChar>?) {
    guard let box = box(host), let message else { return }
    let text = String(cString: message)
    MainActor.assumeIsolated {
        switch level {
        case 0: box.context.logger.debug(text)
        case 1: box.context.logger.info(text)
        case 2: box.context.logger.warning(text)
        default: box.context.logger.error(text)
        }
    }
}

private func chPerformBackground(
    _ host: UnsafeMutableRawPointer?,
    _ work: (@convention(c) (UnsafeMutableRawPointer?) -> Void)?,
    _ ctx: UnsafeMutableRawPointer?
) -> Int32 {
    guard let box = box(host), let work else { return -1 }
    let context = RawPointer(ctx)
    box.performBackground {
        work(context.value)
    }
    return 0
}
