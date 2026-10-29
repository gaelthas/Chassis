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
                .frame(width: 96, alignment: .trailing)

            if granted {
                EmptyView()
            } else if restricted {
                Button("permissions.openSettings") {
                    environment.gate.openSystemSettingsPane(capability)
                }
            } else {
                Button("permissions.grant") {
                    environment.gate.requestFromUserInterface(capability)
                }
                Button("permissions.openSettings") {
                    environment.gate.openSystemSettingsPane(capability)
                }
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

    private var statusLabel: some View {
        Group {
            if restricted {
                Label("permissions.status.restricted", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            } else if granted {
                Label("permissions.status.granted", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Label("permissions.status.notGranted", systemImage: "circle")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .labelStyle(.titleAndIcon)
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
                .frame(width: 96, alignment: .trailing)

            if environment.notifier.authorization != .authorized {
                Button("permissions.grant") {
                    Task { _ = await environment.notifier.requestAuthorization() }
                }
                Button("permissions.openSettings") {
                    SystemSettingsPane.open(.notifications)
                }
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch environment.notifier.authorization {
        case .authorized:
            Label("permissions.status.granted", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.caption)
        case .denied:
            Label("permissions.status.notGranted", systemImage: "circle")
                .foregroundStyle(.secondary)
                .font(.caption)
        case .notDetermined:
            Label("permissions.status.notDetermined", systemImage: "circle.dashed")
                .foregroundStyle(.secondary)
                .font(.caption)
        }
    }
}
