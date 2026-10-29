import PluginKit
import SwiftUI

struct SettingsRootView: View {
    let environment: HostEnvironment

    var body: some View {
        NavigationSplitView {
            List(selection: paneSelection) {
                ForEach(SettingsPane.allCases) { pane in
                    Label(pane.titleKey, systemImage: pane.symbolName)
                        .tag(pane)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 190, max: 220)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(AppIdentity.name)
        .frame(minWidth: 720, minHeight: 520)
    }

    private var paneSelection: Binding<SettingsPane?> {
        Binding(
            get: { environment.selectedPane },
            set: { if let pane = $0 { environment.selectedPane = pane } }
        )
    }

    @ViewBuilder
    private var detail: some View {
        switch environment.selectedPane {
        case .general:
            GeneralPane(environment: environment)
        case .plugins:
            PluginListPane(environment: environment)
        case .marketplace:
            MarketplacePane(environment: environment)
        case .permissions:
            PermissionPane(environment: environment)
        case .about:
            AboutPane(environment: environment)
        }
    }
}
