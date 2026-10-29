import PluginAPI
import PluginKit
import SwiftUI

extension Capability {
    var titleKey: LocalizedStringKey {
        switch self {
        case .accessibility: "capability.accessibility.title"
        case .inputMonitoring: "capability.inputMonitoring.title"
        case .screenCapture: "capability.screenCapture.title"
        }
    }

    var detailKey: LocalizedStringKey {
        switch self {
        case .accessibility: "capability.accessibility.detail"
        case .inputMonitoring: "capability.inputMonitoring.detail"
        case .screenCapture: "capability.screenCapture.detail"
        }
    }
}

extension Capability {
    /// 插件行里的短标签，与权限页的完整标题区分。
    var badgeKey: LocalizedStringKey {
        switch self {
        case .accessibility: "capability.badge.accessibility"
        case .inputMonitoring: "capability.badge.inputMonitoring"
        case .screenCapture: "capability.badge.screenCapture"
        }
    }
}

extension PluginRegistry.State {
    var titleKey: LocalizedStringKey {
        switch self {
        case .disabled: "plugins.state.disabled"
        case .missingCapabilities: "plugins.state.missing"
        case .active: "plugins.state.active"
        case .failed: "plugins.state.failed"
        }
    }

    var tint: Color {
        switch self {
        case .disabled: .secondary
        case .missingCapabilities: .orange
        case .active: .green
        case .failed: .red
        }
    }
}
