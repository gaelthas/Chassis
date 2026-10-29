// swift-tools-version: 6.0
import PackageDescription

/// 接口层独立成包：基座与插件仓库都以路径依赖引用它，两边都能单独构建。
///
/// 包里只有 protocol / struct / enum，唯一实现是 `AtomicFlag`（tap 线程不允许动态派发）
/// 与其依赖的 C 原子垫片 `AtomicsShim`（macOS 14 没有 Synchronization.Atomic）。
let package = Package(
    name: "PluginAPI",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PluginAPI", targets: ["PluginAPI"]),
        .library(name: "AtomicsShim", targets: ["AtomicsShim"]),
    ],
    targets: [
        .target(name: "AtomicsShim"),
        .target(name: "PluginAPI", dependencies: ["AtomicsShim"]),
    ]
)
