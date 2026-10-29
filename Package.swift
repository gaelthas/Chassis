// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Chassis",
    defaultLocalization: "zh-Hans",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PluginAPI", targets: ["PluginAPI"]),
        .library(name: "PluginKit", targets: ["PluginKit"]),
        .library(name: "PluginSupport", targets: ["PluginSupport"]),
        .library(name: "Harness", targets: ["Harness"]),
    ],
    targets: [
        // 唯一一个 C target：tap 线程需要无锁原子，而 macOS 14 目标下没有 Synchronization.Atomic。
        // 不引入 swift-atomics 是刻意的：一个 40 行的 C 垫片就能满足「无锁、无分配、无 ARC」。
        .target(
            name: "AtomicsShim",
            path: "Packages/AtomicsShim"
        ),
        .target(
            name: "PluginAPI",
            dependencies: ["AtomicsShim"],
            path: "Packages/PluginAPI/Sources/PluginAPI"
        ),
        .target(
            name: "PluginKit",
            dependencies: ["PluginAPI", "AtomicsShim"],
            path: "Packages/PluginKit/Sources/PluginKit"
        ),
        .target(
            name: "PluginSupport",
            dependencies: ["PluginAPI"],
            path: "Packages/PluginSupport/Sources/PluginSupport"
        ),
        .target(
            name: "Harness",
            dependencies: ["PluginAPI", "PluginSupport"],
            path: "Packages/Plugins/Harness",
            resources: [.process("Resources")]
        ),
    ]
)
