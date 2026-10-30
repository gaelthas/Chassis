import Foundation

/// 一个插件市场来源。
///
/// 官方市场来自 Info.plist（`ChassisMarketplaceURL` / `ChassisMarketplacePublicKey`），
/// 用户在设置里可以追加任意第三方市场；每个来源自带签名公钥，互不共享信任。
public struct MarketplaceSource: Codable, Identifiable, Hashable, Sendable {
    public static let officialID = "official"

    public var id: String
    public var name: String
    public var url: String
    /// base64 Ed25519 公钥；为空时只有 DEBUG 的本地来源可用。
    public var publicKey: String
    public var isOfficial: Bool
    public var isEnabled: Bool

    public init(
        id: String,
        name: String,
        url: String,
        publicKey: String = "",
        isOfficial: Bool = false,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.publicKey = publicKey
        self.isOfficial = isOfficial
        self.isEnabled = isEnabled
    }

    public var resolvedURL: URL? {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed) else { return nil }
        return url
    }

    /// 官方来源从 Info.plist 构造；地址为空表示没有内置市场。
    public static func bundledOfficial() -> MarketplaceSource? {
        let url = (Bundle.main.object(forInfoDictionaryKey: "ChassisMarketplaceURL") as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return nil }
        let key = Bundle.main.object(forInfoDictionaryKey: "ChassisMarketplacePublicKey") as? String ?? ""
        return MarketplaceSource(
            id: officialID,
            name: "官方市场",
            url: url,
            publicKey: key.trimmingCharacters(in: .whitespacesAndNewlines),
            isOfficial: true,
            isEnabled: true
        )
    }
}
