import PluginAPI
import PluginKit
import SwiftUI

/// 安装确认页：清单、发行方、签名与请求的能力，**在加载任何代码之前**展示。
struct InstallPluginSheet: View {
    let staged: StagedPlugin
    let onInstall: () -> Void
    let onCancel: () -> Void

    private var required: Set<Capability> {
        staged.manifest.capabilitySet.required
    }

    private var capabilities: [Capability] {
        (Array(staged.manifest.capabilitySet.required) + Array(staged.manifest.capabilitySet.optional))
            .sorted { $0.rawValue < $1.rawValue }
    }

    private var titleText: String {
        staged.manifest.title.resolve()
    }

    private var summaryText: String {
        staged.manifest.summary.resolve()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            metadata

            if !capabilities.isEmpty {
                capabilityList
            }

            warning
            actions
        }
        .padding(20)
        .frame(width: 520)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("install.title")
                .font(.headline)
            Text(verbatim: titleText)
                .font(.title3.weight(.semibold))
            Text(verbatim: summaryText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 5) {
            row(label: "install.version", value: staged.manifest.version)
            row(label: "install.identifier", value: staged.manifest.id)
            if let vendor = staged.manifest.vendor, !vendor.isEmpty {
                row(label: "install.publisher", value: vendor)
            }
            HStack(spacing: 8) {
                Text("install.signature")
                    .foregroundStyle(.secondary)
                    .frame(width: 70, alignment: .leading)
                if staged.isDevelopmentSigned {
                    Text("install.signature.development")
                        .foregroundStyle(.orange)
                } else {
                    Text(verbatim: staged.teamID ?? "-")
                        .textSelection(.enabled)
                }
            }
        }
        .font(.callout)
    }

    private func row(label: LocalizedStringKey, value: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)
            Text(verbatim: value)
                .textSelection(.enabled)
        }
    }

    private var capabilityList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("install.capabilities")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            ForEach(capabilities, id: \.self) { capability in
                HStack(spacing: 6) {
                    Image(systemName: required.contains(capability) ? "checkmark.circle.fill" : "circle.dashed")
                        .foregroundStyle(required.contains(capability) ? Color.green : Color.secondary)
                    Text(capability.titleKey)
                    Text(capability.detailKey)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Text("install.capabilities.note")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var warning: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("install.warning")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var actions: some View {
        HStack {
            Spacer()
            Button("common.cancel", role: .cancel) { onCancel() }
            Button("install.confirm") { onInstall() }
                .keyboardShortcut(.defaultAction)
        }
    }
}
