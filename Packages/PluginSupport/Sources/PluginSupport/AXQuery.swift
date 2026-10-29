import ApplicationServices
import Foundation

/// AX 属性读取的便捷函数。
///
/// 这些调用是跨进程同步 IPC，目标应用无响应时可能阻塞数秒——**必须在 `performBackground` 内执行**（§5.2）。
/// 函数本身无状态、不做权限判断；没有辅助功能授权时系统会静默失败，返回 nil。
public enum AXQuery {
    public static func application(pid: pid_t) -> AXUIElement {
        AXUIElementCreateApplication(pid)
    }

    public static func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    public static func boolAttribute(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return (value as? NSNumber)?.boolValue
    }

    public static func pointAttribute(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let axValue = value, CFGetTypeID(axValue) == AXValueGetTypeID() else {
            return nil
        }
        var point = CGPoint.zero
        guard AXValueGetValue(axValue as! AXValue, .cgPoint, &point) else { return nil }
        return point
    }

    public static func sizeAttribute(_ element: AXUIElement, _ attribute: String) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let axValue = value, CFGetTypeID(axValue) == AXValueGetTypeID() else {
            return nil
        }
        var size = CGSize.zero
        guard AXValueGetValue(axValue as! AXValue, .cgSize, &size) else { return nil }
        return size
    }

    /// 枚举某应用的窗口（`kAXWindowsAttribute`）。结果仍是 AX 对象，不能在闭包外跨线程传递，
    /// 需要转换后再返回给主线程。
    public static func windows(of pid: pid_t) -> [AXUIElement] {
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success else {
            return []
        }
        return value as? [AXUIElement] ?? []
    }

    /// 窗口标题。注意：日志里禁止记录该值（§6.8）。
    public static func title(of window: AXUIElement) -> String? {
        stringAttribute(window, kAXTitleAttribute as String)
    }

    public static func isMinimized(_ window: AXUIElement) -> Bool? {
        boolAttribute(window, kAXMinimizedAttribute as String)
    }
}
