import AppKit
import PluginKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // LSUIElement 已声明，这里再显式设置一次，避免从 Xcode 直接运行时占 Dock。
        NSApp.setActivationPolicy(.accessory)

        let environment = HostEnvironment.shared
        environment.bootstrap()

        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                environment.refreshAfterActivation()
            }
        }

        if environment.settings.showSettingsOnLaunch || environment.registry.installedCount == 0 {
            SettingsWindowController.shared.show(environment: environment)
        }
    }

    /// 菜单栏图标被关闭后，这里是唯一的「把用户放回来」的路径（C7）。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsWindowController.shared.show(environment: HostEnvironment.shared)
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        // 按注册逆序关闭，让插件有机会清理自己的 Timer / Task / 观察者。
        HostEnvironment.shared.registry.shutdown()
    }
}
