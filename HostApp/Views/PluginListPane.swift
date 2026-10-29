import AppKit
import PluginAPI
import PluginKit
import SwiftUI
import UniformTypeIdentifiers

struct PluginListPane: View {
    let environment: HostEnvironment

    @State private var selection: String?
    @State private var consentTarget: ConsentTarget?
    @State private var detailTarget: ConsentTarget?
    @State private var staged: StagedPlugin?
    @State private var installError: String?

    private struct ConsentTarget: Identifiable {
        let manifest: PluginManifest
        var id: String { manifest.id }
    }

    var body: some View {
        VStack(spacing: 0) {
            header

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
                        PluginRow(
                            environment: environment,
                            entry: entry,
                            onRequestConsent: { manifest in
                                consentTarget = ConsentTarget(manifest: manifest)
                            },
                            onShowDetail: { manifest in
                                detailTarget = ConsentTarget(manifest: manifest)
                            }
                        )
                        .tag(entry.id)
                    }
                }
                .listStyle(.inset)
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
        .sheet(item: $detailTarget) { target in
            PluginDetailSheet(
                environment: environment,
                manifest: target.manifest,
                onRequestConsent: { consentTarget = ConsentTarget(manifest: target.manifest) },
                onUninstall: {
                    try? environment.uninstallExternalPlugin(id: target.manifest.id)
                    PluginSettingsWindowController.shared.close(pluginID: target.manifest.id)
                    detailTarget = nil
                },
                onClose: { detailTarget = nil }
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
    let onShowDetail: (PluginManifest) -> Void

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

            // 详情入口：开关右侧的 ⓘ，打开二级弹窗。
            Button {
                onShowDetail(entry.manifest)
            } label: {
                Image(systemName: "info.circle")
                    .font(.system(size: 15))
            }
            .buttonStyle(.borderless)
            .help(Text("plugins.detail.help"))
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

private extension PluginSource {
    var isExternal: Bool {
        if case .external = self { return true }
        return false
    }
}
