import AppKit
import PluginAPI
import PluginKit
import UniformTypeIdentifiers

/// 诊断包：无崩溃隔离时这是排障的第一手材料（§6.9）。
/// 内容只包含版本、插件清单、权限状态与最近日志——不含窗口标题、路径、剪贴板、用户输入。
@MainActor
enum DiagnosticsExporter {
    static func text(environment: HostEnvironment) -> String {
        let registry = environment.registry
        var lines: [String] = []

        lines.append("== Application ==")
        lines.append("name: \(AppIdentity.name)")
        lines.append("bundleID: \(AppIdentity.bundleIdentifier)")
        lines.append("version: \(AppIdentity.version) (\(AppIdentity.build))")
        lines.append("")

        lines.append("== Plugins ==")
        if registry.installedCount == 0 {
            lines.append("(none)")
        }
        for entry in registry.entries {
            let capabilities = entry.manifest.requiredCapabilities
                .sorted { $0.rawValue < $1.rawValue }
                .map(\.rawValue)
                .joined(separator: ",")
            lines.append("\(entry.manifest.id) v\(entry.manifest.version) state=\(describe(entry.state)) enabled=\(entry.isEnabled) required=[\(capabilities)]")
        }
        lines.append("")

        lines.append("== Permissions ==")
        for capability in Capability.allCases {
            let consumers = environment.gate.consumers(of: capability)
            lines.append("\(capability.rawValue): granted=\(environment.gate.status(of: capability)) restricted=\(environment.gate.isRestricted(capability)) consumers=\(consumers.count)")
        }
        lines.append("notifications: \(describe(environment.notifier.authorization))")
        lines.append("")

        lines.append("== Inputs ==")
        lines.append("keyboardTap=\(environment.inputBus.hasKeyboardTap) mouseTap=\(environment.inputBus.hasMouseTap) pointerMonitor=\(environment.inputBus.hasPointerMonitor)")
        lines.append("")

        lines.append("== Recent Logs ==")
        let formatter = ISO8601DateFormatter()
        for entry in environment.logStore.snapshot(limit: 100) {
            let owner = entry.pluginID ?? "host"
            lines.append("\(formatter.string(from: entry.date)) [\(describe(entry.level))] [\(owner)] \(entry.message)")
        }

        return lines.joined(separator: "\n")
    }

    static func export(environment: HostEnvironment) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(AppIdentity.name)-diagnostics.txt"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }
        let content = text(environment: environment)
        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            environment.launchAtLoginError = error.localizedDescription
        }
    }

    private static func describe(_ state: PluginRegistry.State) -> String {
        switch state {
        case .disabled: return "disabled"
        case let .missingCapabilities(missing):
            return "missingCapabilities(\(missing.map(\.rawValue).sorted().joined(separator: ",")))"
        case .active: return "active"
        case let .failed(message): return "failed(\(message))"
        }
    }

    private static func describe(_ authorization: NotificationAuthorization) -> String {
        switch authorization {
        case .notDetermined: return "notDetermined"
        case .denied: return "denied"
        case .authorized: return "authorized"
        }
    }

    private static func describe(_ level: LogLevel) -> String {
        switch level {
        case .debug: return "debug"
        case .info: return "info"
        case .warning: return "warning"
        case .error: return "error"
        }
    }
}
