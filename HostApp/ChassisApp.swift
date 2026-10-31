import AppKit
import PluginKit
import SwiftUI

@main
struct ChassisApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var environment = HostEnvironment.shared

    var body: some Scene {
        // 菜单栏图标是唯一的常驻存在。关闭后（isInserted = false）应用依然存活，
        // 用户可通过再次启动应用打开设置窗口。
        MenuBarExtra(isInserted: menuBarInserted) {
            MenuBarMenu(environment: environment)
        } label: {
            Image("MenuBarIcon")
                .renderingMode(.template)
                .accessibilityLabel(Text("menuBar.icon.label"))
        }
        .menuBarExtraStyle(.menu)
    }

    /// `MenuBarExtraController` 用 KVO 监视 `NSStatusItem`，状态一变就在回调里同步回写这个 binding。
    /// 若把回写直接落到 `HostSettings`，会形成：写偏好 → 整棵视图重算 → 改 `NSStatusItem` →
    /// KVO 再回写 → 继续写偏好 的无限循环（AttributeGraph 节点无限增长）。
    /// 因此：同值回写直接丢弃；确实需要改偏好时挪出当前更新栈，避免在 KVO 回调里改可观察状态。
    private var menuBarInserted: Binding<Bool> {
        Binding(
            get: { environment.settings.showMenuBarIcon },
            set: { newValue in
                guard newValue != environment.settings.showMenuBarIcon else { return }
                // 两道检查都要保留：值在 true/false 之间抖动时，仅靠同步 guard 拦不住。
                Task { @MainActor in
                    guard newValue != environment.settings.showMenuBarIcon else { return }
                    environment.settings.showMenuBarIcon = newValue
                }
            }
        )
    }
}

private struct MenuBarMenu: View {
    let environment: HostEnvironment

    var body: some View {
        Button("menu.openSettings") {
            SettingsWindowController.shared.show(environment: environment)
        }
        .keyboardShortcut(",", modifiers: .command)

        Button("menu.about") {
            SettingsWindowController.shared.show(environment: environment, pane: .about)
        }

        Divider()

        Button("menu.quit") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }
}
