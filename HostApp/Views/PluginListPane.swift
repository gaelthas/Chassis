import PluginAPI
import PluginKit
import SwiftUI

struct PluginListPane: View {
    let environment: HostEnvironment
    @State private var selection: String?

    var body: some View {
        Group {
            if environment.registry.installedCount == 0 {
                emptyState
            } else {
                VStack(spacing: 0) {
                    List(selection: $selection) {
                        ForEach(environment.registry.entries) { entry in
                            PluginRow(environment: environment, entry: entry)
                                .tag(entry.id)
                        }
                    }
                    .listStyle(.inset)

                    Divider()

                    detail
                        .frame(minHeight: 210)
                }
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("plugins.empty.title", systemImage: "puzzlepiece.extension")
        } description: {
            Text("plugins.empty.detail")
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let id = selection, let manifest = environment.registry.manifest(of: id) {
            PluginDetailView(environment: environment, manifest: manifest)
        } else {
            Text("plugins.select.hint")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct PluginRow: View {
    let environment: HostEnvironment
    let entry: PluginRegistry.Entry

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: entry.manifest.iconSystemName)
                .font(.system(size: 18))
                .frame(width: 24)
                .foregroundStyle(.tint)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(entry.manifest.title, bundle: entry.manifest.resourceBundle)
                        .font(.body)
                    Text(verbatim: "v\(entry.manifest.version)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 6) {
                    ForEach(Array(entry.manifest.requiredCapabilities).sorted(by: { $0.rawValue < $1.rawValue }), id: \.self) { capability in
                        CapabilityBadge(capability: capability)
                    }
                    Text(entry.state.titleKey)
                        .font(.caption2)
                        .foregroundStyle(entry.state.tint)
                }
            }

            Spacer(minLength: 12)

            Toggle(
                "",
                isOn: Binding(
                    get: { entry.isEnabled },
                    set: { environment.registry.setEnabled(entry.id, enabled: $0) }
                )
            )
            .labelsHidden()
            .toggleStyle(.switch)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

private struct CapabilityBadge: View {
    let capability: Capability

    var body: some View {
        Text(capability.badgeKey)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Color.secondary.opacity(0.14), in: Capsule())
            .foregroundStyle(.secondary)
    }
}

extension Capability {
    var badgeKey: LocalizedStringKey {
        switch self {
        case .accessibility: "capability.badge.accessibility"
        case .inputMonitoring: "capability.badge.inputMonitoring"
        case .screenCapture: "capability.badge.screenCapture"
        }
    }
}

private struct PluginDetailView: View {
    let environment: HostEnvironment
    let manifest: PluginManifest

    private var state: PluginRegistry.State {
        environment.registry.state(of: manifest.id)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Text(manifest.title, bundle: manifest.resourceBundle)
                        .font(.headline)
                    Text(state.titleKey)
                        .font(.caption)
                        .foregroundStyle(state.tint)
                }

                Text(manifest.summary, bundle: manifest.resourceBundle)
                    .font(.callout)
                    .foregroundStyle(.secondary)

                content

                Divider()

                HStack {
                    Button("plugins.resetConfiguration") {
                        environment.registry.resetConfiguration(for: manifest.id)
                    }
                    Spacer()
                    Text(verbatim: manifest.id)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .active:
            // 插件视图只在 active 时构建：半初始化时构建极易触发插件内部的隐式假设（§6.6）。
            if let view = environment.registry.makeSettingsView(for: manifest.id) {
                view
            } else {
                Text("plugins.noSettingsView")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

        case let .missingCapabilities(missing):
            VStack(alignment: .leading, spacing: 8) {
                Text("plugins.missing.explain")
                    .font(.callout)
                HStack(spacing: 8) {
                    ForEach(Array(missing).sorted(by: { $0.rawValue < $1.rawValue }), id: \.self) { capability in
                        Button(capability.titleKey) {
                            environment.gate.request(capability)
                        }
                    }
                    Button("permissions.openSettings") {
                        for capability in missing {
                            environment.gate.openSystemSettingsPane(capability)
                        }
                    }
                }
            }

        case let .failed(message):
            VStack(alignment: .leading, spacing: 8) {
                Text("plugins.failed.explain")
                    .font(.callout)
                Text(message)
                    .font(.caption.monospaced())
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                Button("plugins.retry") {
                    environment.registry.retry(manifest.id)
                }
            }

        case .disabled:
            Text("plugins.disabled.explain")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}
