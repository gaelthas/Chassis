// swift-tools-version: 6.0
import PackageDescription

/// 基座仓库的根包：只承载基座机制（PluginKit）与开发期工具。
/// 插件不参与链接：全部以 `.chassisplugin` 包导入安装。
///
/// - `PluginAPI` / `PluginSupport` 是独立包（`Packages/` 下），插件通过路径依赖引用。
/// - `PluginABI` 是外部插件的 C 边界；插件以动态库形式打进 `.chassisplugin` 包。
let package = Package(
    name: "Chassis",
    defaultLocalization: "zh-Hans",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PluginKit", targets: ["PluginKit"]),
    ],
    dependencies: [
        .package(path: "Packages/PluginAPI"),
        .package(path: "Packages/PluginABI"),
    ],
    targets: [
        .target(
            name: "PluginKit",
            dependencies: [
                .product(name: "PluginAPI", package: "PluginAPI"),
                .product(name: "AtomicsShim", package: "PluginAPI"),
                .product(name: "PluginABI", package: "PluginABI"),
            ],
            path: "Packages/PluginKit/Sources/PluginKit"
        ),
        // 开发期工具：校验并实际加载一个外部插件包（不随应用分发）
        .executableTarget(
            name: "PluginCheck",
            dependencies: ["PluginKit"],
            path: "Tools/PluginCheck",
            linkerSettings: [.unsafeFlags(["-Xlinker", "-export_dynamic"])]
        ),
        .executableTarget(
            name: "MarketCheck",
            dependencies: ["PluginKit"],
            path: "Tools/MarketCheck",
            linkerSettings: [.unsafeFlags(["-Xlinker", "-export_dynamic"])]
        ),
    ]
)
