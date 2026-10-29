// swift-tools-version: 6.0
import PackageDescription

/// 基座仓库的根包：只承载基座机制（PluginKit）与插件的链接入口（Harness）。
///
/// - `PluginAPI` / `PluginSupport` 是独立包（`Packages/` 下），插件仓库与基座共用。
/// - `Harness` 的源码在独立仓库 `Chassis-Plugins`（不被本仓库跟踪），这里用路径把它
///   编进同一个二进制：静态链接模型下「注册表即链接清单」（设计文档 §10）。
///   该目录缺失时构建会失败，`Scripts/bootstrap.sh` 会提示先把插件仓库放到位。
let package = Package(
    name: "Chassis",
    defaultLocalization: "zh-Hans",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PluginKit", targets: ["PluginKit"]),
        .library(name: "Harness", targets: ["Harness"]),
        .library(name: "DockActions", targets: ["DockActions"]),
        .library(name: "SlowQuit", targets: ["SlowQuit"]),
        .library(name: "WindowSwitcher", targets: ["WindowSwitcher"]),
        .library(name: "DockHoverPreview", targets: ["DockHoverPreview"]),
        .library(name: "UsageStatistics", targets: ["UsageStatistics"]),
    ],
    dependencies: [
        .package(path: "Packages/PluginAPI"),
        .package(path: "Packages/PluginSupport"),
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
            path: "Tools/PluginCheck"
        ),
        .executableTarget(
            name: "MarketCheck",
            dependencies: ["PluginKit"],
            path: "Tools/MarketCheck"
        ),
        .target(
            name: "Harness",
            dependencies: [
                .product(name: "PluginAPI", package: "PluginAPI"),
                .product(name: "PluginSupport", package: "PluginSupport"),
            ],
            path: "Chassis-Plugins/Packages/Harness",
            resources: [.process("Resources")]
        ),
        .target(
            name: "DockActions",
            dependencies: [
                .product(name: "PluginAPI", package: "PluginAPI"),
            ],
            path: "Chassis-Plugins/Packages/DockActions",
            resources: [.process("Resources")]
        ),
        .target(
            name: "SlowQuit",
            dependencies: [
                .product(name: "PluginAPI", package: "PluginAPI"),
            ],
            path: "Chassis-Plugins/Packages/SlowQuit",
            resources: [.process("Resources")]
        ),
        .target(
            name: "WindowSwitcher",
            dependencies: [
                .product(name: "PluginAPI", package: "PluginAPI"),
            ],
            path: "Chassis-Plugins/Packages/WindowSwitcher",
            resources: [.process("Resources")]
        ),
        .target(
            name: "DockHoverPreview",
            dependencies: [
                .product(name: "PluginAPI", package: "PluginAPI"),
            ],
            path: "Chassis-Plugins/Packages/DockHoverPreview",
            resources: [.process("Resources")]
        ),
        .target(
            name: "UsageStatistics",
            dependencies: [
                .product(name: "PluginAPI", package: "PluginAPI"),
            ],
            path: "Chassis-Plugins/Packages/UsageStatistics",
            resources: [.process("Resources")]
        ),
    ]
)
