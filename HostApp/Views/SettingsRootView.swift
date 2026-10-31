import AppKit
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
            VStack(spacing: 0) {
                sidebarHeader
                List(selection: paneSelection) {
                    ForEach(SettingsPane.allCases) { pane in
                        Label(pane.titleKey, systemImage: pane.symbolName)
                            .tag(pane)
                    }
                }
                .listStyle(.sidebar)
            }
            .frame(width: 200)

            Divider()

            detail
                .id(environment.selectedPane)
                .transition(.opacity)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .animation(.easeOut(duration: 0.18), value: environment.selectedPane)
        .frame(minWidth: 720, minHeight: 520)
    }

    /// 侧边栏顶部的应用标识：让设置窗口一眼能看出属于哪个应用，
    /// 也和插件行、市场行的图标风格保持同一套视觉语言。
    private var sidebarHeader: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 32, height: 32)
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: AppIdentity.name)
                    .font(.callout.weight(.semibold))
                Text("about.version \(AppIdentity.versionDisplay)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 6)
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
