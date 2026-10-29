import CryptoKit
import Foundation
import PluginAPI

/// 用户对**某一个插件**的能力授权记录。这是 TCC 之外的第二层门控（外部插件设计 §5）。
public struct PluginConsent: Codable, Equatable, Sendable {
    public var granted: Set<Capability>
    /// 清单指纹：插件升级后若新增能力声明，旧同意不继承，必须重新确认。
    public var manifestFingerprint: String
    public var updatedAt: Date

    public init(granted: Set<Capability>, manifestFingerprint: String, updatedAt: Date = Date()) {
        self.granted = granted
        self.manifestFingerprint = manifestFingerprint
        self.updatedAt = updatedAt
    }
}

/// 按插件保存授权，与 TCC 无关：TCC 只授予基座一次，这里决定「基座愿意替这个插件做什么」。
@MainActor
public final class PluginConsentStore {
    private let defaults: UserDefaults
    private let keyPrefix = "consent."
    private var cache: [String: PluginConsent] = [:]

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func consent(for id: String) -> PluginConsent? {
        if let cached = cache[id] { return cached }
        guard let data = defaults.data(forKey: keyPrefix + id),
              let consent = try? JSONDecoder().decode(PluginConsent.self, from: data) else {
            return nil
        }
        cache[id] = consent
        return consent
    }

    public func set(_ consent: PluginConsent, for id: String) {
        var updated = consent
        updated.updatedAt = Date()
        cache[id] = updated
        guard let data = try? JSONEncoder().encode(updated) else { return }
        defaults.set(data, forKey: keyPrefix + id)
    }

    public func clear(_ id: String) {
        cache.removeValue(forKey: id)
        defaults.removeObject(forKey: keyPrefix + id)
    }

    /// 仅由能力声明与版本组成：正文/图标变更不应触发重新授权，能力变化必须触发。
    public static func fingerprint(manifest: PluginManifest) -> String {
        let required = manifest.requiredCapabilities.map(\.rawValue).sorted().joined(separator: ",")
        let optional = manifest.optionalCapabilities.map(\.rawValue).sorted().joined(separator: ",")
        let raw = "\(manifest.id)|\(manifest.version)|\(required)|\(optional)"
        let digest = SHA256.hash(data: Data(raw.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
