// swift-tools-version: 6.0
import PackageDescription

/// 可选共享工具包：纯函数 + `HotKeyRecorder` 控件。无状态、无全局资源、不做权限判断。
/// 插件仓库与基座都以路径依赖引用它。
let package = Package(
    name: "PluginSupport",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PluginSupport", targets: ["PluginSupport"]),
    ],
    dependencies: [
        .package(path: "../PluginAPI"),
    ],
    targets: [
        .target(
            name: "PluginSupport",
            dependencies: [
                .product(name: "PluginAPI", package: "PluginAPI"),
            ],
            path: "Sources/PluginSupport"
        ),
    ]
)
