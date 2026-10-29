import CryptoKit
import Foundation

/// 插件市场索引的获取与包下载。
///
/// 信任模型：
/// - 索引用**内置公钥**校验 Ed25519 签名（公钥来自 Info.plist，可被用户配置覆盖，便于自建市场）。
/// - 未配置公钥时：DEBUG 允许本地来源（file:// / localhost）的未签名索引，方便本地联调；
///   Release 一律拒绝，避免「忘了签名」变成默认行为。
public struct MarketplaceClient: Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - 索引

    public func fetchIndex(from url: URL, publicKeyBase64: String?) async throws -> MarketplaceIndex {
        let data = try await load(url)

        let key = publicKeyBase64?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !key.isEmpty {
            guard let envelope = try? JSONDecoder.marketplace.decode(MarketplaceEnvelope.self, from: data) else {
                throw MarketplaceError.missingSignature
            }
            try Self.verify(envelope: envelope, publicKeyBase64: key)
            return try Self.decodeIndex(Data(envelope.payload.utf8))
        }

        #if DEBUG
        if let envelope = try? JSONDecoder.marketplace.decode(MarketplaceEnvelope.self, from: data) {
            guard Self.isLocal(url) else { throw MarketplaceError.missingSignature }
            return try Self.decodeIndex(Data(envelope.payload.utf8))
        }
        guard Self.isLocal(url) else { throw MarketplaceError.missingSignature }
        return try Self.decodeIndex(data)
        #else
        throw MarketplaceError.missingSignature
        #endif
    }

    // MARK: - 下载

    /// 下载到 `directory`，校验 sha256 后返回本地 zip 路径。
    public func download(_ plugin: MarketplacePlugin, into directory: URL) async throws -> URL {
        let data = try await load(plugin.downloadURL)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest.caseInsensitiveCompare(plugin.sha256) == .orderedSame else {
            throw MarketplaceError.checksumMismatch
        }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("\(plugin.id)-\(plugin.version).zip")
        do {
            try data.write(to: destination, options: .atomic)
        } catch {
            throw MarketplaceError.downloadFailed(error.localizedDescription)
        }
        return destination
    }

    // MARK: - 私有

    private func load(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw MarketplaceError.http(http.statusCode)
            }
            return data
        } catch let error as MarketplaceError {
            throw error
        } catch {
            throw MarketplaceError.transport(error.localizedDescription)
        }
    }

    private static func decodeIndex(_ data: Data) throws -> MarketplaceIndex {
        let index: MarketplaceIndex
        do {
            index = try JSONDecoder.marketplace.decode(MarketplaceIndex.self, from: data)
        } catch {
            throw MarketplaceError.decoding(error.localizedDescription)
        }
        guard index.schema == 1 else { throw MarketplaceError.unsupportedSchema(index.schema) }
        return index
    }

    private static func verify(envelope: MarketplaceEnvelope, publicKeyBase64: String) throws {
        guard let keyData = Data(base64Encoded: publicKeyBase64) else {
            throw MarketplaceError.invalidPublicKey
        }
        guard let signature = Data(base64Encoded: envelope.signature) else {
            throw MarketplaceError.invalidSignature
        }
        let publicKey: Curve25519.Signing.PublicKey
        do {
            publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: keyData)
        } catch {
            throw MarketplaceError.invalidPublicKey
        }
        guard publicKey.isValidSignature(signature, for: Data(envelope.payload.utf8)) else {
            throw MarketplaceError.invalidSignature
        }
    }

    private static func isLocal(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "file": return true
        case "http", "https":
            let host = url.host?.lowercased() ?? ""
            return host == "localhost" || host == "127.0.0.1" || host == "::1"
        default: return false
        }
    }
}

extension JSONDecoder {
    /// 市场两端（发布脚本 / 基座）共用同一套日期策略。
    static var marketplace: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

extension JSONEncoder {
    static var marketplace: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
