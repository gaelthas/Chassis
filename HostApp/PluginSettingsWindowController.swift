import AppKit
import SwiftUI

/// 插件设置窗口。刻意做成独立窗口而不是详情页里的一块：
/// 用户在调参数时经常需要切回系统设置或应用本身，弹窗会挡住操作。
@MainActor
final class PluginSettingsWindowController {
    static let shared = PluginSettingsWindowController()

    private var windows: [String: NSWindow] = [:]

    func show(pluginID: String, title: String, content: AnyView) {
        if let existing = windows[pluginID] {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingController(rootView: content)
        let window = NSWindow(contentViewController: hosting)
        window.title = title
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 560, height: 560))
        window.minSize = NSSize(width: 480, height: 360)
        window.center()

        windows[pluginID] = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close(pluginID: String) {
        windows[pluginID]?.close()
        windows[pluginID] = nil
    }

    func closeAll() {
        windows.values.forEach { $0.close() }
        windows.removeAll()
    }
}
