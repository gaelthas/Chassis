import AppKit
import PluginKit
import SwiftUI

enum SettingsPane: String, CaseIterable, Identifiable, Hashable {
    case general
    case plugins
    case marketplace
    case permissions
    case about

    var id: String { rawValue }

    var titleKey: LocalizedStringKey {
        switch self {
        case .general: "pane.general"
        case .plugins: "pane.plugins"
        case .marketplace: "pane.marketplace"
        case .permissions: "pane.permissions"
        case .about: "pane.about"
        }
    }

    var symbolName: String {
        switch self {
        case .general: "gearshape"
        case .plugins: "puzzlepiece.extension"
        case .marketplace: "bag"
        case .permissions: "lock.shield"
        case .about: "info.circle"
        }
    }
}

/// 设置窗口。用 AppKit 持有窗口而不是 SwiftUI `Window` scene：
/// 菜单栏图标关闭后仍需要一条确定的路径把窗口重新叫出来（C7），
/// `NSWindow` 的引用比 SwiftUI scene 的可达性更可控。
@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()

    private var window: NSWindow?
    private var keyObserver: NSObjectProtocol?

    var isSettingsWindowKey: Bool {
        window?.isKeyWindow ?? false
    }

    func show(environment: HostEnvironment, pane: SettingsPane? = nil) {
        if let pane {
            environment.selectedPane = pane
        }

        if window == nil {
            let hosting = NSHostingController(rootView: SettingsRootView(environment: environment))
            let window = NSWindow(contentViewController: hosting)
            window.title = AppIdentity.name
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 760, height: 560))
            window.minSize = NSSize(width: 720, height: 520)
            window.center()
            self.window = window

            // 用户从系统设置切回本窗口时立刻重探测，而不是等应用级 didBecomeActive。
            // 这是「系统里已授权但界面仍显示未授权」最直接的修复点之一。
            keyObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: window,
                queue: .main
            ) { _ in
                MainActor.assumeIsolated {
                    environment.refreshAfterActivation()
                }
            }
        }

        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        window?.close()
    }
}
