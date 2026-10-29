import PluginKit
import SwiftUI

/// 设置窗口根视图。
///
/// 刻意不用 `NavigationSplitView`：它依赖窗口工具栏/安全区来摆放侧边栏与折叠按钮，
/// 在自建的 `NSWindow` + `NSHostingController` 里会让内容整体上移、顶部条目被标题栏裁掉
/// （macOS 26 上尤其明显）。这里用 `HStack` + `List` 自己控制布局，完全没有系统 chrome。
struct SettingsRootView: View {
    let environment: HostEnvironment

    var body: some View {
        HStack(spacing: 0) {
            List(selection: paneSelection) {
                ForEach(SettingsPane.allCases) { pane in
                    Label(pane.titleKey, systemImage: pane.symbolName)
                        .tag(pane)
                }
            }
            .listStyle(.sidebar)
            .frame(width: 190)

            Divider()

            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
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
