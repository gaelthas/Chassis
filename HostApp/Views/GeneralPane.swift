import AppKit
import PluginKit
import SwiftUI

struct GeneralPane: View {
    let environment: HostEnvironment

    @State private var launchAtLoginEnabled = LaunchAtLogin.isEnabled
    @State private var showHideMenuBarConfirmation = false

    var body: some View {
        Form {
            Section("general.section.startup") {
                Toggle("general.launchAtLogin", isOn: launchAtLoginBinding)
                Text("general.launchAtLogin.caption")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let error = environment.launchAtLoginError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("general.section.window") {
                Toggle("general.showMenuBarIcon", isOn: menuBarBinding)
                Text("general.showMenuBarIcon.caption")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("general.showSettingsOnLaunch", isOn: showSettingsOnLaunchBinding)
            }

            Section("general.section.quit") {
                Button("general.quit", role: .destructive) {
                    NSApp.terminate(nil)
                }
                Text("general.quit.caption")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task {
            launchAtLoginEnabled = LaunchAtLogin.isEnabled
        }
        .confirmationDialog(
            "general.menuBar.confirm.title",
            isPresented: $showHideMenuBarConfirmation,
            titleVisibility: .visible
        ) {
            Button("general.menuBar.confirm.action", role: .destructive) {
                environment.settings.showMenuBarIcon = false
            }
            Button("common.cancel", role: .cancel) {}
        } message: {
            Text("general.menuBar.confirm.message")
        }
    }

    /// 开机自启：失败必须回滚开关，不能出现「UI 已开启但系统未注册」（C8）。
    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLoginEnabled },
            set: { newValue in
                do {
                    try LaunchAtLogin.set(newValue)
                    environment.launchAtLoginError = nil
                } catch {
                    environment.launchAtLoginError = error.localizedDescription
                }
                launchAtLoginEnabled = LaunchAtLogin.isEnabled
            }
        )
    }

    /// 关闭菜单栏图标是「可能把自己锁在外面」的操作，先说明再执行（C7）。
    private var menuBarBinding: Binding<Bool> {
        Binding(
            get: { environment.settings.showMenuBarIcon },
            set: { newValue in
                if newValue {
                    environment.settings.showMenuBarIcon = true
                } else {
                    showHideMenuBarConfirmation = true
                }
            }
        )
    }

    private var showSettingsOnLaunchBinding: Binding<Bool> {
        Binding(
            get: { environment.settings.showSettingsOnLaunch },
            set: { environment.settings.showSettingsOnLaunch = $0 }
        )
    }
}
