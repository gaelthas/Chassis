import Foundation
import ServiceManagement

/// 开机自启：以 `SMAppService.mainApp.status` 为唯一真实状态，不做本地持久化。
/// 注册可能失败（例如应用不在 /Applications），调用方必须捕获并把开关回滚（C8）。
enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static var isAvailable: Bool {
        SMAppService.mainApp.status != .notRegistered
            ? true
            : Bundle.main.bundlePath.hasSuffix(".app")
    }

    static func set(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
