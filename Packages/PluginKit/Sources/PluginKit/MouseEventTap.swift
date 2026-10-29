import AtomicsShim
import CoreGraphics
import Foundation
import PluginAPI

/// 鼠标点击的不可变订阅快照（与键盘同构）。
final class ClickSnapshot: @unchecked Sendable {
    struct Route: Sendable {
        let delivery: DeliveryBox<ClickContext>
    }

    let routes: [Route]

    init(routes: [Route]) {
        self.routes = routes
    }
}

final class MouseTapRuntime: @unchecked Sendable {
    let snapshotSlot: OpaquePointer
    let frontmostSlot: OpaquePointer
    let relay: InterruptionRelay

    var machPort: CFMachPort?
    var runLoop: CFRunLoop?

    // 以下字段只在 tap 线程访问：有效点击判定所需的「按下时刻」标量。
    var leftDownTime: UInt64 = 0
    var leftDownPoint: CGPoint = .zero
    var leftDownValid = false
    var rightDownTime: UInt64 = 0
    var rightDownPoint: CGPoint = .zero
    var rightDownValid = false
    var otherDownTime: UInt64 = 0
    var otherDownPoint: CGPoint = .zero
    var otherDownValid = false

    /// 判定阈值由基座内部定义，不作为 API 参数暴露（§6.3）。
    static let maxClickDurationNanos: UInt64 = 400_000_000  // 0.4s
    static let maxClickDistance: CGFloat = 4.0

    init(snapshotSlot: OpaquePointer, frontmostSlot: OpaquePointer, relay: InterruptionRelay) {
        self.snapshotSlot = snapshotSlot
        self.frontmostSlot = frontmostSlot
        self.relay = relay
    }
}

private func mouseTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let runtime = Unmanaged<MouseTapRuntime>.fromOpaque(refcon).takeUnretainedValue()

    switch type {
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
        var recovered = false
        if let port = runtime.machPort {
            CGEvent.tapEnable(tap: port, enable: true)
            recovered = CGEvent.tapIsEnabled(tap: port)
        }
        runtime.relay.send(InputInterruption(source: .pointer, reason: .timeoutDisabled, recovered: recovered))
        return Unmanaged.passUnretained(event)

    case .leftMouseDown:
        runtime.leftDownTime = event.timestamp
        runtime.leftDownPoint = event.location
        runtime.leftDownValid = true

    case .rightMouseDown:
        runtime.rightDownTime = event.timestamp
        runtime.rightDownPoint = event.location
        runtime.rightDownValid = true

    case .otherMouseDown:
        runtime.otherDownTime = event.timestamp
        runtime.otherDownPoint = event.location
        runtime.otherDownValid = true

    case .leftMouseUp:
        if runtime.leftDownValid {
            runtime.leftDownValid = false
            deliverClick(
                runtime: runtime,
                downTime: runtime.leftDownTime,
                downPoint: runtime.leftDownPoint,
                upEvent: event,
                button: .left
            )
        }

    case .rightMouseUp:
        if runtime.rightDownValid {
            runtime.rightDownValid = false
            deliverClick(
                runtime: runtime,
                downTime: runtime.rightDownTime,
                downPoint: runtime.rightDownPoint,
                upEvent: event,
                button: .right
            )
        }

    case .otherMouseUp:
        if runtime.otherDownValid {
            runtime.otherDownValid = false
            deliverClick(
                runtime: runtime,
                downTime: runtime.otherDownTime,
                downPoint: runtime.otherDownPoint,
                upEvent: event,
                button: .other
            )
        }

    default:
        break
    }

    return Unmanaged.passUnretained(event)
}

/// 有效点击判定在 mouseUp 时完成：位移小且时长在预算内才算点击，拖拽天然被排除。
private func deliverClick(
    runtime: MouseTapRuntime,
    downTime: UInt64,
    downPoint: CGPoint,
    upEvent: CGEvent,
    button: MouseButton
) {
    let upTime = upEvent.timestamp
    guard upTime >= downTime, upTime - downTime <= MouseTapRuntime.maxClickDurationNanos else { return }

    let upPoint = upEvent.location
    let dx = upPoint.x - downPoint.x
    let dy = upPoint.y - downPoint.y
    guard (dx * dx + dy * dy).squareRoot() <= MouseTapRuntime.maxClickDistance else { return }

    guard let pointer = ch_atomic_ptr_load(runtime.snapshotSlot) else { return }
    let snapshot = Unmanaged<ClickSnapshot>.fromOpaque(pointer).takeUnretainedValue()
    guard !snapshot.routes.isEmpty else { return }

    let pidValue = ch_atomic_int_load(runtime.frontmostSlot)
    let clickCount = Int(upEvent.getIntegerValueField(.mouseEventClickState))
    let context = ClickContext(
        location: upPoint,
        timestamp: TimeInterval(upTime) / 1_000_000_000,
        button: button,
        clickCount: clickCount,
        frontmostPID: pidValue > 0 ? pid_t(pidValue) : nil
    )

    for route in snapshot.routes {
        route.delivery.dispatch(context)
    }
}

/// 鼠标 tap：`.listenOnly`，绝不介入原生 Dock 悬停与点击语义（ADR-5）。
@MainActor
final class MouseEventTap {
    private let runtime: MouseTapRuntime
    private var thread: Thread?
    private var onCreationResult: ((Bool) -> Void)?

    private static let mouseMask: CGEventMask = {
        let types: [CGEventType] = [
            .leftMouseDown, .leftMouseUp,
            .rightMouseDown, .rightMouseUp,
            .otherMouseDown, .otherMouseUp,
            .tapDisabledByTimeout, .tapDisabledByUserInput,
        ]
        return types.reduce(CGEventMask(0)) { partial, type in
            partial | (CGEventMask(1) << CGEventMask(type.rawValue))
        }
    }()

    init(snapshotSlot: OpaquePointer, frontmostSlot: OpaquePointer, relay: InterruptionRelay) {
        runtime = MouseTapRuntime(snapshotSlot: snapshotSlot, frontmostSlot: frontmostSlot, relay: relay)
    }

    func start(completion: ((Bool) -> Void)? = nil) {
        guard thread == nil else {
            completion?(true)
            return
        }
        onCreationResult = completion
        let runtime = self.runtime

        let mask = Self.mouseMask

        let thread = Thread { [weak self, runtime] in
            guard let port = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .listenOnly,
                eventsOfInterest: mask,
                callback: mouseTapCallback,
                userInfo: Unmanaged.passUnretained(runtime).toOpaque()
            ) else {
                runtime.relay.send(InputInterruption(source: .pointer, reason: .tapCreationFailed, recovered: false))
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
        thread.name = "com.gaelthas.chassis.tap.mouse"
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
