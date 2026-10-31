import AppKit
import PluginKit
import SwiftUI

struct GeneralPane: View {
    let environment: HostEnvironment

    @State private var launchAtLoginEnabled = LaunchAtLogin.isEnabled
    @State private var showHideMenuBarConfirmation = false

    var body: some View {
        Form {
            Section {
                Toggle("general.launchAtLogin", isOn: launchAtLoginBinding)
            } header: {
                Text("general.section.startup")
            } footer: {
                if let error = environment.launchAtLoginError {
                    Text(error)
                        .foregroundStyle(.red)
                } else {
                    Text("general.launchAtLogin.caption")
                }
            }

            Section {
                Toggle("general.showMenuBarIcon", isOn: menuBarBinding)
                Toggle("general.showSettingsOnLaunch", isOn: showSettingsOnLaunchBinding)
            } header: {
                Text("general.section.window")
            } footer: {
                Text("general.showMenuBarIcon.caption")
            }

            Section {
                Toggle("general.allowThirdParty", isOn: allowThirdPartyBinding)
            } header: {
                Text("general.section.plugins")
            } footer: {
                Text("general.allowThirdParty.caption")
            }

            Section {
                Button("general.quit", role: .destructive) {
                    NSApp.terminate(nil)
                }
            } header: {
                Text("general.section.quit")
            } footer: {
                Text("general.quit.caption")
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

    private var allowThirdPartyBinding: Binding<Bool> {
        Binding(
            get: { environment.settings.allowThirdPartyPlugins },
            set: { environment.settings.allowThirdPartyPlugins = $0 }
        )
    }

    private var showSettingsOnLaunchBinding: Binding<Bool> {
        Binding(
            get: { environment.settings.showSettingsOnLaunch },
            set: { environment.settings.showSettingsOnLaunch = $0 }
        )
    }
}
