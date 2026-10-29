import Foundation

/// 插件市场索引（`index.json` 的 payload 部分）。
///
/// 设计取舍：
/// - 市场只提供**元数据**，安装仍然走 `PluginInstaller` 的完整校验链路，市场不是信任根。
/// - 索引必须被签名（`MarketplaceEnvelope`）；签名覆盖 payload 的**原始字节**，避免 JSON 规范化歧义。
/// - `sha256` 是包完整性校验：签名保证清单可信，摘要保证下载到的文件就是清单里那一个。
public struct MarketplaceIndex: Codable, Sendable {
    public let schema: Int
    public let generatedAt: Date
    public let plugins: [MarketplacePlugin]

    public init(schema: Int = 1, generatedAt: Date = Date(), plugins: [MarketplacePlugin]) {
        self.schema = schema
        self.generatedAt = generatedAt
        self.plugins = plugins
    }
}

public struct MarketplacePlugin: Codable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let summary: String
    public let version: String
    public let minHostVersion: String
    public let apiVersion: Int
    public let downloadURL: URL
    public let sha256: String
    public let size: Int?
    public let vendor: String?
    public let requiredCapabilities: [String]
    public let optionalCapabilities: [String]
    public let homepage: URL?

    public var identifier: String { id }

    public init(
        id: String,
        name: String,
        summary: String,
        version: String,
        minHostVersion: String,
        apiVersion: Int = 1,
        downloadURL: URL,
        sha256: String,
        size: Int? = nil,
        vendor: String? = nil,
        requiredCapabilities: [String] = [],
        optionalCapabilities: [String] = [],
        homepage: URL? = nil
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.version = version
        self.minHostVersion = minHostVersion
        self.apiVersion = apiVersion
        self.downloadURL = downloadURL
        self.sha256 = sha256
        self.size = size
        self.vendor = vendor
        self.requiredCapabilities = requiredCapabilities
        self.optionalCapabilities = optionalCapabilities
        self.homepage = homepage
    }
}

/// 签名信封：`payload` 是索引 JSON 的原文，`signature` 是它对 Ed25519 私钥的签名（base64）。
public struct MarketplaceEnvelope: Codable, Sendable {
    public let payload: String
    public let signature: String

    public init(payload: String, signature: String) {
        self.payload = payload
        self.signature = signature
    }
}

public enum MarketplaceError: LocalizedError, Equatable {
    case notConfigured
    case transport(String)
    case http(Int)
    case missingSignature
    case invalidSignature
    case invalidPublicKey
    case decoding(String)
    case unsupportedSchema(Int)
    case downloadFailed(String)
    case checksumMismatch

    public var errorDescription: String? {
        switch self {
        case .notConfigured: return "未配置插件市场地址"
        case let .transport(detail): return "无法访问插件市场：\(detail)"
        case let .http(code): return "插件市场返回 HTTP \(code)"
        case .missingSignature: return "索引缺少签名（正式构建必须签名）"
        case .invalidSignature: return "索引签名校验失败"
        case .invalidPublicKey: return "内置的插件市场公钥无效"
        case let .decoding(detail): return "索引解析失败：\(detail)"
        case let .unsupportedSchema(value): return "不支持的索引版本：\(value)"
        case let .downloadFailed(detail): return "插件下载失败：\(detail)"
        case .checksumMismatch: return "插件包校验和不匹配，已放弃安装"
        }
    }
}
