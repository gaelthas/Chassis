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

    private var menuBarInserted: Binding<Bool> {
        Binding(
            get: { environment.settings.showMenuBarIcon },
            set: { environment.settings.showMenuBarIcon = $0 }
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
