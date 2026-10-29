// swift-tools-version: 6.0
import PackageDescription

/// 外部插件 ABI 独立成包：第三方插件与基座都以路径依赖引用同一份头文件，
/// 且插件**不需要**依赖 PluginAPI/PluginKit（纯 C 边界）。
let package = Package(
    name: "PluginABI",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PluginABI", targets: ["PluginABI"]),
    ],
    targets: [
        .target(name: "PluginABI"),
    ]
)
