import AppKit
import PluginKit
import SwiftUI

struct AboutPane: View {
    let environment: HostEnvironment

    private var updateURL: URL? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "ChassisUpdateURL") as? String else { return nil }
        return URL(string: raw)
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .accessibilityHidden(true)

            VStack(spacing: 4) {
                Text(verbatim: AppIdentity.name)
                    .font(.title2.weight(.semibold))
                Text("about.version \(AppIdentity.versionDisplay)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if !AppIdentity.summary.isEmpty {
                Text(verbatim: AppIdentity.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }

            Divider()
                .frame(width: 320)

            VStack(spacing: 8) {
                HStack {
                    Text("about.hostVersion")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(verbatim: AppIdentity.versionDisplay)
                        .monospacedDigit()
                }
                HStack {
                    Text("about.plugins")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("about.plugins.count \(environment.registry.enabledCount) \(environment.registry.installedCount)")
                        .monospacedDigit()
                }
            }
            .frame(width: 320)

            HStack(spacing: 10) {
                Button {
                    DiagnosticsExporter.export(environment: environment)
                } label: {
                    Label("about.exportDiagnostics", systemImage: "square.and.arrow.up")
                }
                Button {
                    if let updateURL {
                        NSWorkspace.shared.open(updateURL)
                    }
                } label: {
                    Label("about.checkUpdates", systemImage: "arrow.down.circle")
                }
                .disabled(updateURL == nil)
            }

            Spacer(minLength: 4)

            Text(verbatim: AppIdentity.copyright)
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
