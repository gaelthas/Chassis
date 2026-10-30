import PluginAPI
import PluginKit
import SwiftUI

/// 插件详情（二级弹窗）。入口是插件行开关右侧的 ⓘ 按钮。
struct PluginDetailSheet: View {
    let environment: HostEnvironment
    let manifest: PluginManifest
    let onRequestConsent: () -> Void
    let onClose: () -> Void

    private var id: String { manifest.id }

    private var state: PluginRegistry.State {
        environment.registry.state(of: id)
    }

    private var declared: [Capability] {
        environment.registry.declaredCapabilities(of: id).sorted { $0.rawValue < $1.rawValue }
    }

    private var granted: Set<Capability> {
        environment.registry.grantedConsent(of: id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(manifest.summary, bundle: manifest.resourceBundle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if case let .external(info) = environment.registry.source(of: id) {
                        externalInfo(info)
                    }

                    consentSection
                    content
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()
            footer
        }
        .frame(width: 560, height: 540)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: manifest.iconSystemName)
                .font(.system(size: 22))
                .frame(width: 30)
                .foregroundStyle(.tint)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(manifest.title, bundle: manifest.resourceBundle)
                        .font(.headline)
                    Text(verbatim: "v\(manifest.version)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    Text(state.titleKey)
                        .font(.caption2)
                        .foregroundStyle(state.tint)
                    Text(verbatim: id)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }
            }

            Spacer()
        }
        .padding(16)
    }

    private var footer: some View {
        HStack {
            Button("plugins.resetConfiguration") {
                environment.registry.resetConfiguration(for: id)
            }
            Spacer()
            Button("common.close") { onClose() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(12)
    }

    @ViewBuilder
    private var consentSection: some View {
        if !declared.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("plugins.consent.section")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                ForEach(declared, id: \.self) { capability in
                    Toggle(isOn: binding(for: capability)) {
                        HStack(spacing: 6) {
                            Text(capability.titleKey)
                            if manifest.requiredCapabilities.contains(capability) {
                                Text("plugins.consent.required")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            if !environment.gate.status(of: capability) {
                                Text("plugins.consent.systemMissing")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                }

                Text("plugins.consent.hint")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func binding(for capability: Capability) -> Binding<Bool> {
        Binding(
            get: { granted.contains(capability) },
            set: { isOn in
                if isOn {
                    environment.registry.grantConsent(id, capabilities: granted.union([capability]))
                } else {
                    environment.registry.revokeConsent(id, capability: capability)
                }
            }
        )
    }

    private func externalInfo(_ info: ExternalPluginInfo) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent("install.version", value: info.version)
            // 不展示原始 Team ID：它对用户没有意义，也不是需要公开的信息。
            // 信任判断只保留「是否与基座同一开发者」，原始值仍可在诊断导出里查到。
            LabeledContent("install.publisher") {
                if let teamID = info.teamID, teamID == AppIdentity.teamID {
                    Text("install.publisher.sameTeam")
                } else {
                    Text("install.publisher.thirdParty")
                }
            }
            LabeledContent("install.installedAt") {
                Text(verbatim: info.installedAt.formatted(date: .abbreviated, time: .shortened))
            }
            LabeledContent("install.location") {
                Text(verbatim: info.path)
                    .font(.caption2)
                    .textSelection(.enabled)
            }
        }
        .font(.caption)
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .active:
            Text("plugins.settingsInWindow")
                .font(.caption)
                .foregroundStyle(.secondary)

        case let .missingCapabilities(missing):
            VStack(alignment: .leading, spacing: 8) {
                Text("plugins.missing.explain")
                    .font(.callout)

                HStack(spacing: 8) {
                    if !environment.registry.missingConsent(of: id).isEmpty {
                        Button("plugins.consent.grant") { onRequestConsent() }
                    }
                    ForEach(Array(missing).sorted(by: { $0.rawValue < $1.rawValue }), id: \.self) { capability in
                        if environment.gate.status(of: capability) {
                            Button(capability.titleKey) {
                                environment.registry.grantConsent(id, capabilities: granted.union([capability]))
                            }
                        } else {
                            Button(capability.titleKey) {
                                environment.gate.request(capability)
                            }
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
                Text(verbatim: message)
                    .font(.caption.monospaced())
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                Button("plugins.retry") {
                    environment.registry.retry(id)
                }
            }

        case .disabled:
            Text("plugins.disabled.explain")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}
