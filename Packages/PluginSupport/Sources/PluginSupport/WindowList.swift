import CoreGraphics
import Foundation

/// 窗口的纯值快照。`CGWindowID` / `pid_t` / `CGRect` 都是标量，可跨线程传递。
public struct WindowInfo: Sendable, Identifiable, Hashable {
    public let windowID: CGWindowID
    public let pid: pid_t
    public let bounds: CGRect
    public let layer: Int
    public let ownerName: String?

    public var id: CGWindowID { windowID }

    public init(windowID: CGWindowID, pid: pid_t, bounds: CGRect, layer: Int, ownerName: String?) {
        self.windowID = windowID
        self.pid = pid
        self.bounds = bounds
        self.layer = layer
        self.ownerName = ownerName
    }
}

/// 窗口枚举。`CGWindowListCopyWindowInfo` 是跨进程调用，可能因目标应用卡顿而变慢，
/// 调用方必须包在 `performBackground` 里（§7）。不读窗口标题——那需要 AX 权限。
public enum WindowList {
    public static func onScreenWindows(excludingWindowID: CGWindowID? = nil) -> [WindowInfo] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        return list.compactMap { entry -> WindowInfo? in
            guard let windowID = entry[kCGWindowNumber as String] as? CGWindowID else { return nil }
            if let excludingWindowID, windowID == excludingWindowID { return nil }
            guard let pidNumber = entry[kCGWindowOwnerPID as String] as? NSNumber else { return nil }
            let layer = (entry[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            let ownerName = entry[kCGWindowOwnerName as String] as? String
            let boundsDictionary = entry[kCGWindowBounds as String] as? NSDictionary
            let bounds = boundsDictionary.flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) } ?? .zero

            return WindowInfo(
                windowID: windowID,
                pid: pid_t(pidNumber.int32Value),
                bounds: bounds,
                layer: layer,
                ownerName: ownerName
            )
        }
    }
}
