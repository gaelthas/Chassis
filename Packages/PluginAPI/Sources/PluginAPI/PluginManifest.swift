import Foundation
import SwiftUI

/// 插件的静态元信息，可在不实例化插件的前提下完整获取。
///
/// 这里刻意没有 `settingsView`：设置页是 `FeaturePlugin.makeSettingsView()` 实例方法，
/// 否则闭包写在 `static` 上永远拿不到实例状态，切换页面即丢失未保存的编辑（ADR-21）。
public struct PluginManifest {
    /// 反向域名，全局唯一；一经发布不可更改（它同时是配置存储的 suite 名）。
    public let id: String
    public let version: String
    /// 构建期校验：插件要求的最低基座版本。运行时不做版本判断（§6.7）。
    public let minHostVersion: String
    public let title: LocalizedStringKey
    public let summary: LocalizedStringKey
    public let iconSystemName: String
    /// 缺一不可，否则插件不激活。
    public let requiredCapabilities: Set<Capability>
    /// 缺失时降级运行。
    public let optionalCapabilities: Set<Capability>
    /// 插件自己的资源（本地化字符串、图片）。渲染时一律 `Text(title, bundle: resourceBundle)`。
    public let resourceBundle: Bundle

    public init(
        id: String,
        version: String,
        minHostVersion: String,
        title: LocalizedStringKey,
        summary: LocalizedStringKey,
        iconSystemName: String,
        requiredCapabilities: Set<Capability> = [],
        optionalCapabilities: Set<Capability> = [],
        resourceBundle: Bundle
    ) {
        self.id = id
        self.version = version
        self.minHostVersion = minHostVersion
        self.title = title
        self.summary = summary
        self.iconSystemName = iconSystemName
        self.requiredCapabilities = requiredCapabilities
        self.optionalCapabilities = optionalCapabilities
        self.resourceBundle = resourceBundle
    }
}
