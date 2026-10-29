import PluginAPI
import PluginKit
import SwiftUI

/// 逐插件授权确认面板。
///
/// 必须在文案里说清两件事：这些能力是基座已有的系统授权（不会再弹系统框），
/// 以及插件与基座同进程、基座只能限制它通过插件 API 的行为。
struct PluginConsentSheet: View {
    let manifest: PluginManifest
    let onConfirm: (Set<Capability>) -> Void
    let onCancel: () -> Void

    @State private var selection: Set<Capability>

    init(
        manifest: PluginManifest,
        onConfirm: @escaping (Set<Capability>) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.manifest = manifest
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        _selection = State(
            initialValue: manifest.requiredCapabilities.union(manifest.optionalCapabilities)
        )
    }

    private var required: [Capability] {
        manifest.requiredCapabilities.sorted { $0.rawValue < $1.rawValue }
    }

    private var optional: [Capability] {
        manifest.optionalCapabilities.sorted { $0.rawValue < $1.rawValue }
    }

    private var canConfirm: Bool {
        manifest.requiredCapabilities.isSubset(of: selection)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("consent.title \(Text(manifest.title, bundle: manifest.resourceBundle))")
                    .font(.headline)
                Text("consent.subtitle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !required.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("consent.requiredSection")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(required, id: \.self) { capability in
                        row(capability, isRequired: true)
                    }
                }
            }

            if !optional.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("consent.optionalSection")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(optional, id: \.self) { capability in
                        row(capability, isRequired: false)
                    }
                }
            }

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("consent.warning")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("common.cancel", role: .cancel) { onCancel() }
                Button("consent.confirm") { onConfirm(selection) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canConfirm)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private func row(_ capability: Capability, isRequired: Bool) -> some View {
        Toggle(isOn: binding(for: capability)) {
            VStack(alignment: .leading, spacing: 2) {
                Text(capability.titleKey)
                Text(capability.detailKey)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func binding(for capability: Capability) -> Binding<Bool> {
        Binding(
            get: { selection.contains(capability) },
            set: { isOn in
                if isOn {
                    selection.insert(capability)
                } else {
                    selection.remove(capability)
                }
            }
        )
    }
}
