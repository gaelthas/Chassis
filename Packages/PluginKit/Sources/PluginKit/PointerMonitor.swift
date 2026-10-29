import AppKit
import CoreGraphics
import Foundation

/// 指针移动监听：`NSEvent` 全局监听，不进 Event Tap。
///
/// 移动事件频率极高，进入 tap 会拖慢全系统输入（ADR-6）。
/// 节流（≤60Hz + 位移阈值）由基座统一完成，插件无法关闭——这是防止插件拖慢主线程的最后一道闸。
@MainActor
final class PointerMonitor {
    private let minInterval: TimeInterval = 1.0 / 60.0
    private let minDistance: CGFloat = 2.0

    private var monitor: Any?
    private var lastEmit: TimeInterval = 0
    private var lastPoint: CGPoint = .zero
    private var hasLast = false

    /// 由总线提供：把节流后的点分发给全部指针订阅。
    private let deliver: @MainActor (CGPoint) -> Void

    init(deliver: @escaping @MainActor (CGPoint) -> Void) {
        self.deliver = deliver
    }

    var isRunning: Bool { monitor != nil }

    /// 返回是否创建成功。缺「辅助功能」授权时全局监听会失败。
    func start() -> Bool {
        guard monitor == nil else { return true }

        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        monitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            // 全局监听回调由 AppKit 在主线程投递；用 assumeIsolated 避免额外队列跳转开销。
            MainActor.assumeIsolated {
                self?.sample()
            }
        }
        if monitor == nil {
            return false
        }
        hasLast = false
        return true
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        hasLast = false
    }

    private func sample() {
        let now = ProcessInfo.processInfo.systemUptime
        if hasLast, now - lastEmit < minInterval { return }

        let appKitPoint = NSEvent.mouseLocation
        let point = ScreenCoordinates.topLeft(appKitPoint)
        if hasLast {
            let dx = point.x - lastPoint.x
            let dy = point.y - lastPoint.y
            if (dx * dx + dy * dy).squareRoot() < minDistance { return }
        }

        lastEmit = now
        lastPoint = point
        hasLast = true
        deliver(point)
    }
}

enum ScreenCoordinates {
    /// AppKit 用左下原点，而 CGEvent 用左上原点。
    /// 统一下发左上坐标，与 `ClickContext.location` 保持同一坐标系。
    static func topLeft(_ point: CGPoint) -> CGPoint {
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
        guard primaryHeight > 0 else { return point }
        return CGPoint(x: point.x, y: primaryHeight - point.y)
    }
}
