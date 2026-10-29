import CoreGraphics
import Foundation

/// 一次有效点击。基座已在 tap 侧完成时间差 / 位移差判定。
///
/// 只携带「事件时刻的标量事实」：点击会改变前台应用，事后再查得到的是新世界（§4.4.3）。
/// 对象化（`NSRunningApplication`）与「点击前窗口状态」都由插件在主线程自行完成。
public struct ClickContext: Sendable {
    /// 全局屏幕坐标（左上原点，与 `CGEvent.location` 同一坐标系）。
    public let location: CGPoint
    /// 单调时钟，仅用于排序/去重，不用于展示。
    public let timestamp: TimeInterval
    public let button: MouseButton
    /// 1 = 单击，2 = 双击。
    public let clickCount: Int
    /// 点击「前」瞬间的前台进程。由基座在主线程维护的原子快照给出。
    public let frontmostPID: pid_t?

    public init(location: CGPoint, timestamp: TimeInterval, button: MouseButton, clickCount: Int, frontmostPID: pid_t?) {
        self.location = location
        self.timestamp = timestamp
        self.button = button
        self.clickCount = clickCount
        self.frontmostPID = frontmostPID
    }
}

public enum MouseButton: Sendable, Hashable {
    case left
    case right
    case other
}
