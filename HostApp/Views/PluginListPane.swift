import AppKit
import PluginAPI
import PluginKit
import SwiftUI
import UniformTypeIdentifiers

struct PluginListPane: View {
    let environment: HostEnvironment

    @State private var selection: String?
    @State private var consentTarget: ConsentTarget?
    @State private var staged: StagedPlugin?
    @State private var installError: String?

    private struct ConsentTarget: Identifiable {
        let manifest: PluginManifest
        var id: String { manifest.id }
    }

    private var availableOffers: [PluginManifest] {
        environment.bundledOffers.filter { !environment.isBundledPluginInstalled($0.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            if !availableOffers.isEmpty {
                offers
                Divider()
            }

            if environment.registry.installedCount == 0 {
                ContentUnavailableView {
                    Label("plugins.empty.title", systemImage: "puzzlepiece.extension")
                } description: {
                    Text("plugins.empty.detail")
                }
                .frame(maxHeight: .infinity)
            } else {
                List(selection: $selection) {
                    ForEach(environment.registry.entries) { entry in
                        PluginRow(environment: environment, entry: entry) { manifest in
                            consentTarget = ConsentTarget(manifest: manifest)
                        }
                        .tag(entry.id)
                    }
                }
                .listStyle(.inset)

                Divider()

                detail
                    .frame(minHeight: 210)
            }
        }
        .sheet(item: $consentTarget) { target in
            PluginConsentSheet(
                manifest: target.manifest,
                onConfirm: { capabilities in
                    guard environment.registry.grantConsent(target.manifest.id, capabilities: capabilities) else {
                        consentTarget = nil
                        return
                    }
                    environment.registry.setEnabled(target.manifest.id, enabled: true)
                    consentTarget = nil
                },
                onCancel: { consentTarget = nil }
            )
        }
        .sheet(item: $staged) { staged in
            InstallPluginSheet(
                staged: staged,
                onInstall: {
                    do {
                        try environment.install(staged)
                        self.staged = nil
                    } catch {
                        installError = error.localizedDescription
                        self.staged = nil
                    }
                },
                onCancel: { self.staged = nil }
            )
        }
        .alert(
            "install.error.title",
            isPresented: Binding(get: { installError != nil }, set: { if !$0 { installError = nil } })
        ) {
            Button("common.ok") { installError = nil }
        } message: {
            Text(verbatim: installError ?? "")
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("plugins.count \(environment.registry.installedCount)")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Button("plugins.install") { choosePackage() }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// 随应用分发但尚未安装的插件。默认零插件时这里是唯一的入口。
    private var offers: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("plugins.bundled.section")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("plugins.bundled.detail")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(availableOffers, id: \.id) { manifest in
                HStack(spacing: 10) {
                    Image(systemName: manifest.iconSystemName)
                        .font(.system(size: 16))
                        .frame(width: 22)
                        .foregroundStyle(.tint)
                    Text(manifest.title, bundle: manifest.resourceBundle)
                    Text(verbatim: "v\(manifest.version)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(manifest.summary, bundle: manifest.resourceBundle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Button("plugins.bundled.install") {
                        environment.installBundledPlugin(id: manifest.id)
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var detail: some View {
        if let id = selection, let manifest = environment.registry.manifest(of: id) {
            PluginDetailView(
                environment: environment,
                manifest: manifest,
                onRequestConsent: { consentTarget = ConsentTarget(manifest: manifest) },
                onUninstall: {
                    if environment.isBundledPlugin(id) {
                        environment.uninstallBundledPlugin(id: id)
                    } else {
                        try? environment.uninstallExternalPlugin(id: id)
                    }
                    selection = nil
                }
            )
        } else {
            Text("plugins.select.hint")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func choosePackage() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "plugins.install.panelTitle")
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = [
            UTType(filenameExtension: "chassisplugin") ?? .package,
            .zip,
        ]
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            staged = try environment.inspectPlugin(at: url)
        } catch {
            installError = error.localizedDescription
        }
    }
}

// MARK: - 列表行

private struct PluginRow: View {
    let environment: HostEnvironment
    let entry: PluginRegistry.Entry
    let onRequestConsent: (PluginManifest) -> Void

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
                    if entry.isExternal {
                        Text("plugins.source.external")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.16), in: Capsule())
                    }
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
                    set: { newValue in
                        // 启用前必须完成「逐插件授权」；没有能力声明的插件直接启用。
                        if newValue, environment.registry.needsConsentPrompt(entry.id) {
                            onRequestConsent(entry.manifest)
                        } else {
                            environment.registry.setEnabled(entry.id, enabled: newValue)
                        }
                    }
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

// MARK: - 详情

private struct PluginDetailView: View {
    let environment: HostEnvironment
    let manifest: PluginManifest
    let onRequestConsent: () -> Void
    let onUninstall: () -> Void

    @State private var confirmUninstall = false

    private var state: PluginRegistry.State {
        environment.registry.state(of: manifest.id)
    }

    private var declared: [Capability] {
        environment.registry.declaredCapabilities(of: manifest.id).sorted { $0.rawValue < $1.rawValue }
    }

    private var granted: Set<Capability> {
        environment.registry.grantedConsent(of: manifest.id)
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

                if case let .external(info) = environment.registry.source(of: manifest.id) {
                    externalInfo(info)
                }

                consentSection

                content

                Divider()

                HStack {
                    Button("plugins.resetConfiguration") {
                        environment.registry.resetConfiguration(for: manifest.id)
                    }
                    if environment.registry.source(of: manifest.id) != nil {
                        Button("plugins.uninstall", role: .destructive) {
                            confirmUninstall = true
                        }
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
        .confirmationDialog("plugins.uninstall.confirm", isPresented: $confirmUninstall, titleVisibility: .visible) {
            Button("plugins.uninstall", role: .destructive) { onUninstall() }
            Button("common.cancel", role: .cancel) {}
        } message: {
            Text("plugins.uninstall.message")
        }
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
                    environment.registry.grantConsent(manifest.id, capabilities: granted.union([capability]))
                } else {
                    environment.registry.revokeConsent(manifest.id, capability: capability)
                }
            }
        )
    }

    private func externalInfo(_ info: ExternalPluginInfo) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
            GridRow {
                Text("install.version").foregroundStyle(.secondary)
                Text(verbatim: info.version)
            }
            GridRow {
                Text("install.signature").foregroundStyle(.secondary)
                Text(verbatim: info.teamID ?? String(localized: "install.signature.development"))
            }
            GridRow {
                Text("install.installedAt").foregroundStyle(.secondary)
                Text(verbatim: info.installedAt.formatted(date: .abbreviated, time: .shortened))
            }
            GridRow {
                Text("install.location").foregroundStyle(.secondary)
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
                    if !environment.registry.missingConsent(of: manifest.id).isEmpty {
                        Button("plugins.consent.grant") { onRequestConsent() }
                    }
                    ForEach(Array(missing).sorted(by: { $0.rawValue < $1.rawValue }), id: \.self) { capability in
                        if environment.gate.status(of: capability) {
                            Button(capability.titleKey) {
                                environment.registry.grantConsent(manifest.id, capabilities: granted.union([capability]))
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

private extension PluginSource {
    var isExternal: Bool {
        if case .external = self { return true }
        return false
    }
}
