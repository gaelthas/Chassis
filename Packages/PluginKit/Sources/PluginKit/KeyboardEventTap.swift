import AtomicsShim
import CoreGraphics
import Foundation
import PluginAPI

/// 键盘 tap 的不可变订阅快照。
///
/// 主线程构造后通过原子指针发布；tap 线程只做原子 load + 只读遍历。
/// 快照在 tap 存活期间不释放，因此 tap 线程不会触发任何 dealloc。
final class KeyboardSnapshot: @unchecked Sendable {
    struct Route: Sendable {
        let keyCodes: Set<Int64>
        let requiredFlags: CGEventFlags
        let syncIntercept: (@Sendable (KeyEvent) -> KeyIntercept)?
        let delivery: DeliveryBox<KeyEvent>

        @inline(__always)
        func matches(keyCode: Int64, flags: CGEventFlags) -> Bool {
            guard keyCodes.contains(keyCode) else { return false }
            guard !requiredFlags.isEmpty else { return true }
            return flags.isSuperset(of: requiredFlags)
        }
    }

    let routes: [Route]

    init(routes: [Route]) {
        self.routes = routes
    }
}

/// tap 线程独占的运行期状态。除 `machPort` / `runLoop` 由主线程在启停时读写外，
/// 其余字段只在 tap 线程访问；类本身不做同步（也不需要）。
final class KeyboardTapRuntime: @unchecked Sendable {
    let snapshotSlot: OpaquePointer
    let frontmostSlot: OpaquePointer
    let relay: InterruptionRelay

    var machPort: CFMachPort?
    var runLoop: CFRunLoop?

    init(snapshotSlot: OpaquePointer, frontmostSlot: OpaquePointer, relay: InterruptionRelay) {
        self.snapshotSlot = snapshotSlot
        self.frontmostSlot = frontmostSlot
        self.relay = relay
    }
}

private func keyboardTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let runtime = Unmanaged<KeyboardTapRuntime>.fromOpaque(refcon).takeUnretainedValue()

    switch type {
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
        // 系统因回调超时静默禁用 tap。不重新 enable 的表现是「功能突然不工作」。
        var recovered = false
        if let port = runtime.machPort {
            CGEvent.tapEnable(tap: port, enable: true)
            recovered = CGEvent.tapIsEnabled(tap: port)
        }
        runtime.relay.send(InputInterruption(source: .keyboard, reason: .timeoutDisabled, recovered: recovered))
        return Unmanaged.passUnretained(event)

    case .keyDown, .keyUp, .flagsChanged:
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0

        guard let pointer = ch_atomic_ptr_load(runtime.snapshotSlot) else {
            return Unmanaged.passUnretained(event)
        }
        // 只读快照；takeUnretainedValue 是仅有的一次 ARC 操作，无分配、无锁。
        let snapshot = Unmanaged<KeyboardSnapshot>.fromOpaque(pointer).takeUnretainedValue()
        var consume = false
        let kind: KeyEventKind
        switch type {
        case .keyDown: kind = .keyDown
        case .keyUp: kind = .keyUp
        default: kind = .flagsChanged
        }
        let keyEvent = KeyEvent(keyCode: keyCode, flags: flags, isRepeat: isRepeat, kind: kind)

        for route in snapshot.routes {
            guard route.matches(keyCode: keyCode, flags: flags) else { continue }
            if let intercept = route.syncIntercept, intercept(keyEvent) == .consume {
                consume = true
            }
            route.delivery.dispatch(keyEvent)
        }

        return consume ? nil : Unmanaged.passUnretained(event)

    default:
        return Unmanaged.passUnretained(event)
    }
}

/// 键盘 tap 的生命周期管理：专属线程 + 专属 runloop。
///
/// `@MainActor` 保证启动/停止只在主线程，tap 线程只碰 `KeyboardTapRuntime`。
@MainActor
final class KeyboardEventTap {
    private let runtime: KeyboardTapRuntime
    private var thread: Thread?
    private var onCreationResult: ((Bool) -> Void)?

    init(snapshotSlot: OpaquePointer, frontmostSlot: OpaquePointer, relay: InterruptionRelay) {
        runtime = KeyboardTapRuntime(snapshotSlot: snapshotSlot, frontmostSlot: frontmostSlot, relay: relay)
    }

    var isRunning: Bool { thread != nil }

    func start(completion: ((Bool) -> Void)? = nil) {
        guard thread == nil else {
            completion?(true)
            return
        }
        onCreationResult = completion
        let runtime = self.runtime

        let mask = CGEventMask(
            (1 << CGEventType.keyDown.rawValue)
                | (1 << CGEventType.keyUp.rawValue)
                | (1 << CGEventType.flagsChanged.rawValue)
                | (1 << CGEventType.tapDisabledByTimeout.rawValue)
                | (1 << CGEventType.tapDisabledByUserInput.rawValue)
        )

        let thread = Thread { [weak self, runtime] in
            guard let port = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: mask,
                callback: keyboardTapCallback,
                userInfo: Unmanaged.passUnretained(runtime).toOpaque()
            ) else {
                // 创建失败最常见的原因是缺「输入监控」授权；Event Tap 返回 nil 不告知原因。
                runtime.relay.send(InputInterruption(source: .keyboard, reason: .tapCreationFailed, recovered: false))
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated { self?.finishCreation(success: false) }
                }
                return
            }

            runtime.machPort = port
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
            let runLoop = CFRunLoopGetCurrent()
            runtime.runLoop = runLoop
            CFRunLoopAddSource(runLoop, source, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)

            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.finishCreation(success: true) }
            }

            CFRunLoopRun()
        }
        thread.name = "com.gaelthas.chassis.tap.keyboard"
        thread.qualityOfService = .userInteractive
        thread.stackSize = 512 * 1024
        self.thread = thread
        thread.start()
    }

    private func finishCreation(success: Bool) {
        let completion = onCreationResult
        onCreationResult = nil
        if !success {
            thread = nil
            runtime.machPort = nil
            runtime.runLoop = nil
        }
        completion?(success)
    }

    func stop() {
        if let port = runtime.machPort {
            CGEvent.tapEnable(tap: port, enable: false)
        }
        if let runLoop = runtime.runLoop {
            CFRunLoopStop(runLoop)
            CFRunLoopWakeUp(runLoop)
        }
        runtime.machPort = nil
        runtime.runLoop = nil
        thread = nil
    }
}
