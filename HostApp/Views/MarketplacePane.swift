import PluginAPI
import PluginKit
import SwiftUI

/// 插件市场页：只负责展示索引与触发安装/更新，校验与安装仍走 `PluginInstaller`。
struct MarketplacePane: View {
    let environment: HostEnvironment

    private var market: PluginUpdateCenter { environment.marketplace }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .task { await market.refreshIfStale() }
    }

    // MARK: - 头部

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("market.title")
                        .font(.title3.weight(.semibold))
                    statusLine
                }
                Spacer()
                Button("market.check") {
                    Task { await market.refresh() }
                }
                .disabled(market.status == .checking || !market.isConfigured)
            }

            HStack(spacing: 18) {
                Toggle("market.autoCheck", isOn: autoCheckBinding)
                Toggle("market.autoInstall", isOn: autoInstallBinding)
                    .disabled(!environment.settings.autoCheckPluginUpdates)
            }
            .toggleStyle(.checkbox)
            .font(.callout)

            Text("market.autoInstall.note")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var statusLine: some View {
        switch market.status {
        case .idle:
            Text("market.neverChecked")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("market.checking")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        case .ready:
            let stamp = market.lastChecked?.formatted(date: .abbreviated, time: .shortened) ?? "-"
            HStack(spacing: 5) {
                Text("market.lastChecked")
                Text(verbatim: stamp)
                Text(verbatim: "·")
                Text("market.updatesAvailable \(market.availableUpdateCount)")
                Text(verbatim: "·")
                Text("market.installableCount \(market.installableCount)")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        case let .failed(message):
            Text(verbatim: message)
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 列表

    @ViewBuilder
    private var content: some View {
        if !market.isConfigured {
            notConfigured
        } else if market.items.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "bag")
                    .font(.system(size: 30))
                    .foregroundStyle(.tertiary)
                Text("market.empty.title")
                    .font(.callout)
                Text("market.empty.detail")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(market.items) { item in
                row(item)
            }
            .listStyle(.inset)
        }
    }

    private func row(_ item: PluginUpdateCenter.Item) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "puzzlepiece.extension")
                .font(.system(size: 20))
                .frame(width: 24)
                .foregroundStyle(.tint)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(verbatim: item.plugin.name)
                        .font(.body)
                    Text(verbatim: "v\(item.plugin.version)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let vendor = item.plugin.vendor {
                        Text(verbatim: vendor)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }

                Text(verbatim: item.plugin.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                HStack(spacing: 6) {
                    ForEach(item.plugin.requiredCapabilities.sorted(), id: \.self) { raw in
                        if let capability = Capability(rawValue: raw) {
                            Text(capability.titleKey)
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Color.secondary.opacity(0.14), in: Capsule())
                        }
                    }
                    if let size = item.plugin.size {
                        Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            Spacer(minLength: 12)
            trailing(item)
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func trailing(_ item: PluginUpdateCenter.Item) -> some View {
        switch item.state {
        case .notInstalled:
            Button("market.install") {
                Task { await market.install(id: item.id) }
            }

        case let .updateAvailable(installedVersion):
            VStack(alignment: .trailing, spacing: 3) {
                Text("market.fromVersion \(installedVersion)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Button("market.update") {
                    Task { await market.install(id: item.id) }
                }
                .buttonStyle(.borderedProminent)
            }

        case .installed:
            Label("market.installed", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)

        case let .incompatible(minimum):
            Text("market.incompatible \(minimum)")
                .font(.caption2)
                .foregroundStyle(.orange)
                .frame(width: 150, alignment: .trailing)

        case let .working(text):
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(verbatim: text).font(.caption)
            }

        case let .failed(message):
            VStack(alignment: .trailing, spacing: 3) {
                Text(verbatim: message)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .frame(width: 220, alignment: .trailing)
                Button("market.retry") {
                    Task { await market.install(id: item.id) }
                }
            }
        }
    }

    // MARK: - 配置与页脚

    private var notConfigured: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("market.notConfigured.title")
                .font(.callout.weight(.medium))
            Text("market.notConfigured.detail")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(verbatim: "ChassisMarketplaceURL / ChassisMarketplacePublicKey")
                .font(.caption.monospaced())
                .textSelection(.enabled)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("market.footer")
                .font(.caption2)
                .foregroundStyle(.secondary)
            if !environment.settings.allowThirdPartyPlugins {
                Text("market.thirdPartyHint")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var autoCheckBinding: Binding<Bool> {
        Binding(
            get: { environment.settings.autoCheckPluginUpdates },
            set: { isOn in
                environment.settings.autoCheckPluginUpdates = isOn
                if isOn {
                    environment.marketplace.startAutomaticUpdates()
                } else {
                    environment.marketplace.stopAutomaticUpdates()
                }
            }
        )
    }

    private var autoInstallBinding: Binding<Bool> {
        Binding(
            get: { environment.settings.autoInstallPluginUpdates },
            set: { environment.settings.autoInstallPluginUpdates = $0 }
        )
    }
}
