import PluginAPI
import PluginKit
import PluginSupport
import SwiftUI

struct PermissionPane: View {
    let environment: HostEnvironment

    var body: some View {
        Form {
            Section("permissions.section.required") {
                ForEach(Capability.allCases, id: \.self) { capability in
                    CapabilityRow(environment: environment, capability: capability)
                }
            }

            Section("permissions.section.optional") {
                NotificationRow(environment: environment)
            }

            Section {
                HStack {
                    Text("permissions.note")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("permissions.recheck") {
                        environment.gate.refresh()
                        Task { await environment.notifier.refreshAuthorization() }
                    }
                    .controlSize(.small)
                }
                Text("permissions.staleNote")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .task {
            // 打开权限页时重探测一次，覆盖「用户刚在系统设置里授权完」的情形。
            environment.gate.refresh()
            await environment.notifier.refreshAuthorization()
        }
    }
}

private struct CapabilityRow: View {
    let environment: HostEnvironment
    let capability: Capability

    private var granted: Bool { environment.gate.status(of: capability) }
    private var restricted: Bool { environment.gate.isRestricted(capability) }
    private var consumers: Int { environment.gate.consumers(of: capability).count }
    private var outcome: PermissionGate.RequestOutcome? { environment.gate.outcomes[capability] }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(capability.titleKey)
                Text(capability.detailKey)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(consumersText)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                if !granted, let hint = hintKey {
                    Text(hint)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 12)

            statusLabel

            if granted {
                EmptyView()
            } else if restricted {
                Button("permissions.openSettings") {
                    environment.gate.openSystemSettingsPane(capability)
                }
                .controlSize(.small)
            } else {
                Button("permissions.grant") {
                    environment.gate.requestFromUserInterface(capability)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                Button("permissions.openSettings") {
                    environment.gate.openSystemSettingsPane(capability)
                }
                .controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }

    private var consumersText: LocalizedStringKey {
        consumers == 0 ? "permissions.noConsumers" : "permissions.consumers \(consumers)"
    }

    private var hintKey: LocalizedStringKey? {
        switch outcome {
        case .waitingForSystem:
            "permissions.hint.waiting"
        case .needsSystemSettings:
            "permissions.hint.manual"
        case .restricted:
            "permissions.hint.restricted"
        case .granted, .none:
            nil
        }
    }

    /// 状态徽章：图标 + 文案装进浅色胶囊，三种状态一眼可分。
    private var statusLabel: some View {
        let (key, icon): (LocalizedStringKey, String)
        let tint: Color
        if restricted {
            (key, icon) = ("permissions.status.restricted", "exclamationmark.triangle.fill")
            tint = .orange
        } else if granted {
            (key, icon) = ("permissions.status.granted", "checkmark.circle.fill")
            tint = .green
        } else {
            (key, icon) = ("permissions.status.notGranted", "circle")
            tint = .secondary
        }
        return HStack(spacing: 4) {
            Image(systemName: icon)
            Text(key)
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(tint.opacity(0.14), in: Capsule())
        .foregroundStyle(tint)
    }
}

private struct NotificationRow: View {
    let environment: HostEnvironment

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("permissions.notification.title")
                Text("permissions.notification.detail")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)

            statusLabel

            if environment.notifier.authorization != .authorized {
                Button("permissions.grant") {
                    Task { _ = await environment.notifier.requestAuthorization() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                Button("permissions.openSettings") {
                    SystemSettingsPane.open(.notifications)
                }
                .controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }

    private var statusInfo: (key: LocalizedStringKey, icon: String, tint: Color) {
        switch environment.notifier.authorization {
        case .authorized:
            ("permissions.status.granted", "checkmark.circle.fill", .green)
        case .denied:
            ("permissions.status.notGranted", "circle", .secondary)
        case .notDetermined:
            ("permissions.status.notDetermined", "circle.dashed", .secondary)
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        let info = statusInfo
        HStack(spacing: 4) {
            Image(systemName: info.icon)
            Text(info.key)
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(info.tint.opacity(0.14), in: Capsule())
        .foregroundStyle(info.tint)
    }
}
