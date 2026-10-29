import Foundation
import PluginAPI

/// `.chassisplugin` 包内的 `manifest.json`。
///
/// 刻意不在加载代码之后才读取：安装列表与授权确认都只依赖这份 JSON，
/// 因此「安装了但没启用」的插件**从未被 dlopen**。
public struct PluginPackageManifest: Codable, Sendable {
    public struct LocalizedText: Codable, Sendable {
        public var values: [String: String]

        public init(values: [String: String]) {
            self.values = values
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let single = try? container.decode(String.self) {
                values = ["en": single]
                return
            }
            values = try container.decode([String: String].self)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(values)
        }

        /// 优先中文，其次英文，最后取任意一个。
        public func resolve(preferred: [String] = ["zh-Hans", "zh-Hant", "en"]) -> String {
            for key in preferred {
                if let value = values[key], !value.isEmpty { return value }
            }
            return values.values.first ?? ""
        }
    }

    public let schema: Int
    public let id: String
    public let version: String
    public let minHostVersion: String
    public let apiVersion: Int
    public let title: LocalizedText
    public let summary: LocalizedText
    public let iconSystemName: String
    public let requiredCapabilities: [String]
    public let optionalCapabilities: [String]
    public let vendor: String?
    public let supportURL: String?

    public init(
        schema: Int = 1,
        id: String,
        version: String,
        minHostVersion: String,
        apiVersion: Int = 1,
        title: LocalizedText,
        summary: LocalizedText,
        iconSystemName: String,
        requiredCapabilities: [String] = [],
        optionalCapabilities: [String] = [],
        vendor: String? = nil,
        supportURL: String? = nil
    ) {
        self.schema = schema
        self.id = id
        self.version = version
        self.minHostVersion = minHostVersion
        self.apiVersion = apiVersion
        self.title = title
        self.summary = summary
        self.iconSystemName = iconSystemName
        self.requiredCapabilities = requiredCapabilities
        self.optionalCapabilities = optionalCapabilities
        self.vendor = vendor
        self.supportURL = supportURL
    }

    public var capabilitySet: (required: Set<Capability>, optional: Set<Capability>) {
        let required = Set(requiredCapabilities.compactMap(Capability.init(rawValue:)))
        let optional = Set(optionalCapabilities.compactMap(Capability.init(rawValue:)))
        return (required, optional)
    }
}

/// 已安装插件的注册表记录。
public struct InstalledPluginRecord: Codable, Sendable, Identifiable {
    public let id: String
    public let version: String
    public let path: String
    public let teamID: String?
    public let installedAt: Date

    public var identifier: String { id }

    public init(id: String, version: String, path: String, teamID: String?, installedAt: Date = Date()) {
        self.id = id
        self.version = version
        self.path = path
        self.teamID = teamID
        self.installedAt = installedAt
    }
}

public enum PluginInstallError: LocalizedError, Equatable {
    case notABundle
    case missingManifest
    case malformedManifest(String)
    case unsupportedSchema(Int)
    case unsupportedAPIVersion(Int)
    case hostTooOld(minimum: String)
    case invalidIdentifier(String)
    case duplicateWithBuiltIn(String)
    case signatureInvalid(String)
    case untrustedSignature(String)
    case ioFailure(String)

    public var errorDescription: String? {
        switch self {
        case .notABundle: return "所选内容不是 .chassisplugin 插件包"
        case .missingManifest: return "插件包缺少 Contents/manifest.json"
        case let .malformedManifest(detail): return "manifest.json 解析失败：\(detail)"
        case let .unsupportedSchema(value): return "不支持的清单版本：\(value)"
        case let .unsupportedAPIVersion(value): return "插件 API 版本 \(value) 与当前基座不兼容"
        case let .hostTooOld(minimum): return "该插件要求基座至少为 \(minimum)"
        case let .invalidIdentifier(value): return "插件 ID 非法：\(value)"
        case let .duplicateWithBuiltIn(value): return "插件 ID 与内置插件冲突：\(value)"
        case let .signatureInvalid(detail): return "签名校验失败：\(detail)"
        case let .untrustedSignature(detail): return "插件签名不受信任：\(detail)"
        case let .ioFailure(detail): return "安装过程出错：\(detail)"
        }
    }
}

enum SemanticVersion {
    /// 仅比较数字段，够用且不引入依赖；预发布标记按「同版本」处理。
    static func isAtLeast(_ version: String, _ minimum: String) -> Bool {
        let lhs = version.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        let rhs = minimum.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        for index in 0..<max(lhs.count, rhs.count) {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right { return left > right }
        }
        return true
    }
}
