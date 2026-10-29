import AppKit
import Foundation
import PluginAPI

/// 跳转系统设置。
///
/// 基座不封装这个动作（§4.4.1），但每个插件都会用到，所以标准 URL 统一放这里，避免各拼一份。
/// URL 由系统决定，跨大版本可能变化；打不开时返回 false，由调用方退回文案提示，不重试。
public enum SystemSettingsPane {
    public enum Pane {
        case accessibility
        case inputMonitoring
        case screenCapture
        case notifications
    }

    @discardableResult
    public static func open(_ pane: Pane) -> Bool {
        let anchor: String
        switch pane {
        case .accessibility:
            anchor = "Privacy_Accessibility"
        case .inputMonitoring:
            anchor = "Privacy_ListenEvent"
        case .screenCapture:
            anchor = "Privacy_ScreenCapture"
        case .notifications:
            let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications")
            return url.map { NSWorkspace.shared.open($0) } ?? false
        }
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else {
            return false
        }
        return NSWorkspace.shared.open(url)
    }

    @discardableResult
    public static func open(_ capability: Capability) -> Bool {
        switch capability {
        case .accessibility:
            return open(Pane.accessibility)
        case .inputMonitoring:
            return open(Pane.inputMonitoring)
        case .screenCapture:
            return open(Pane.screenCapture)
        }
    }
}
