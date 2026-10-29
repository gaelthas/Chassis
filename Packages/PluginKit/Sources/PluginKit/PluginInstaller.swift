import Foundation
import PluginAPI
import Security

/// 安装策略：默认只信任与基座同 Team 签名的插件；
/// 「允许第三方插件」打开后才接受异 Team（含 ad-hoc 开发签名）。
public struct PluginInstallPolicy {
    public let allowedTeamIDs: Set<String>
    public let allowThirdParty: Bool

    public init(allowedTeamIDs: Set<String>, allowThirdParty: Bool) {
        self.allowedTeamIDs = allowedTeamIDs
        self.allowThirdParty = allowThirdParty
    }
}

/// 校验通过的插件包（尚未复制到安装目录）。
public struct StagedPlugin: Identifiable {
    public var id: String { manifest.id }

    public let manifest: PluginPackageManifest
    public let bundleURL: URL
    public let teamID: String?
    public let bundleIdentifier: String?
    public let isDevelopmentSigned: Bool
}

/// 插件包的校验、安装、卸载与注册表。
///
/// 安装分两步：`inspect`（只读、无副作用）→ 用户确认 → `install`。
/// 任何一步失败都不会改动已安装内容。
@MainActor
public final class PluginInstaller {
    private let hostVersion: String
    private let defaults: UserDefaults
    private let recordsKey = "installedPlugins"
    private let fileManager = FileManager.default

    public let pluginsDirectory: URL

    public init(hostVersion: String, defaults: UserDefaults = .standard) {
        self.hostVersion = hostVersion
        self.defaults = defaults

        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let base = support
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.gaelthas.chassis", isDirectory: true)
        pluginsDirectory = base.appendingPathComponent("Plugins", isDirectory: true)
        try? FileManager.default.createDirectory(at: pluginsDirectory, withIntermediateDirectories: true)
    }

    // MARK: - 注册表

    public var records: [InstalledPluginRecord] {
        guard let data = defaults.data(forKey: recordsKey),
              let list = try? JSONDecoder().decode([InstalledPluginRecord].self, from: data) else {
            return []
        }
        return list
    }

    private func write(_ records: [InstalledPluginRecord]) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        defaults.set(data, forKey: recordsKey)
    }

    public func record(for id: String) -> InstalledPluginRecord? {
        records.first { $0.id == id }
    }

    /// 已安装插件声明的能力；用于判断一次更新是否改变了授权范围。
    public func installedCapabilities(id: String) -> (required: Set<String>, optional: Set<String>)? {
        guard let record = record(for: id) else { return nil }
        let bundleURL = URL(fileURLWithPath: record.path)
        guard let manifestURL = Self.manifestURL(in: bundleURL),
              let data = try? Data(contentsOf: manifestURL),
              let package = try? JSONDecoder().decode(PluginPackageManifest.self, from: data) else {
            return nil
        }
        return (Set(package.requiredCapabilities), Set(package.optionalCapabilities))
    }

    // MARK: - 校验

    public func inspect(url: URL, policy: PluginInstallPolicy) throws -> StagedPlugin {
        let bundleURL = try prepareBundle(at: url)

        guard let manifestURL = Self.manifestURL(in: bundleURL) else {
            throw PluginInstallError.missingManifest
        }

        let data: Data
        do {
            data = try Data(contentsOf: manifestURL)
        } catch {
            throw PluginInstallError.ioFailure(error.localizedDescription)
        }

        let package: PluginPackageManifest
        do {
            package = try JSONDecoder().decode(PluginPackageManifest.self, from: data)
        } catch {
            throw PluginInstallError.malformedManifest(error.localizedDescription)
        }

        guard package.schema == 1 else { throw PluginInstallError.unsupportedSchema(package.schema) }
        guard package.apiVersion == 1 else { throw PluginInstallError.unsupportedAPIVersion(package.apiVersion) }
        guard SemanticVersion.isAtLeast(hostVersion, package.minHostVersion) else {
            throw PluginInstallError.hostTooOld(minimum: package.minHostVersion)
        }
        guard Self.isValidIdentifier(package.id) else {
            throw PluginInstallError.invalidIdentifier(package.id)
        }
        // 基座不再内置任何插件，只禁止占用基座自身的 bundle id。
        guard package.id != AppIdentity.bundleIdentifier else {
            throw PluginInstallError.duplicateWithBuiltIn(package.id)
        }

        // 校验整个包：包内只有 Contents/MacOS 下的可执行文件是代码，资源在 Contents/Resources。
        let signature = try Self.verifySignature(at: bundleURL)
        let teamID = signature.teamID

        if !policy.allowThirdParty {
            guard let teamID, policy.allowedTeamIDs.contains(teamID) else {
                throw PluginInstallError.untrustedSignature("该插件不是由受信任的开发者签名；可在通用设置中允许第三方插件")
            }
        }
        if policy.allowThirdParty, signature.isAdHoc {
            // 允许开发签名，但必须显式打开开关，且 UI 会标注「开发签名」。
        }

        return StagedPlugin(
            manifest: package,
            bundleURL: bundleURL,
            teamID: teamID,
            bundleIdentifier: package.id,
            isDevelopmentSigned: signature.isAdHoc
        )
    }

    // MARK: - 安装 / 卸载

    @discardableResult
    public func install(_ staged: StagedPlugin) throws -> InstalledPluginRecord {
        let id = staged.manifest.id
        let destination = pluginsDirectory.appendingPathComponent("\(id).chassisplugin", isDirectory: true)

        do {
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.copyItem(at: staged.bundleURL, to: destination)
        } catch {
            throw PluginInstallError.ioFailure(error.localizedDescription)
        }

        let record = InstalledPluginRecord(
            id: id,
            version: staged.manifest.version,
            path: destination.path,
            teamID: staged.teamID
        )

        var list = records.filter { $0.id != id }
        list.append(record)
        write(list)
        return record
    }

    public func uninstall(id: String) throws {
        guard let record = record(for: id) else { return }
        let url = URL(fileURLWithPath: record.path)
        if fileManager.fileExists(atPath: url.path) {
            // 移到废纸篓而不是静默删除，用户可恢复。
            do {
                try fileManager.trashItem(at: url, resultingItemURL: nil)
            } catch {
                try? fileManager.removeItem(at: url)
            }
        }
        write(records.filter { $0.id != id })
    }

    // MARK: - 私有

    /// 支持目录形态的 `.chassisplugin`；zip 会解到临时目录。
    private func prepareBundle(at url: URL) throws -> URL {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw PluginInstallError.notABundle
        }

        if isDirectory.boolValue {
            guard url.pathExtension == "chassisplugin" else { throw PluginInstallError.notABundle }
            return url
        }

        guard url.pathExtension.lowercased() == "zip" else { throw PluginInstallError.notABundle }
        let destination = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", url.path, destination.path]
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw PluginInstallError.ioFailure(error.localizedDescription)
        }
        guard process.terminationStatus == 0 else {
            throw PluginInstallError.ioFailure("解压失败（ditto exit \(process.terminationStatus)）")
        }

        let contents = try fileManager.contentsOfDirectory(at: destination, includingPropertiesForKeys: nil)
        if let bundle = contents.first(where: { $0.pathExtension == "chassisplugin" }) {
            return bundle
        }
        // 允许 zip 直接包含 Contents/
        if fileManager.fileExists(atPath: destination.appendingPathComponent("Contents/manifest.json").path) {
            return destination
        }
        throw PluginInstallError.notABundle
    }

    private struct SignatureInfo {
        let teamID: String?
        let isAdHoc: Bool
    }

    /// 清单标准位置是 `Contents/Resources/manifest.json`；兼容早期放在 Contents 根的包。
    static func manifestURL(in bundleURL: URL) -> URL? {
        let candidates = [
            bundleURL.appendingPathComponent("Contents/Resources/manifest.json"),
            bundleURL.appendingPathComponent("Contents/manifest.json"),
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func executableURL(in bundleURL: URL) throws -> URL {
        let infoPlist = bundleURL.appendingPathComponent("Contents/Info.plist")
        let declared = (NSDictionary(contentsOf: infoPlist)?["CFBundleExecutable"] as? String)
        let candidates = [
            declared.map { "Contents/MacOS/\($0)" },
            "Contents/MacOS/Plugin",
        ].compactMap { $0 }

        for candidate in candidates {
            let url = bundleURL.appendingPathComponent(candidate)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        throw PluginInstallError.notABundle
    }

    private static func verifySignature(at url: URL) throws -> SignatureInfo {
        var staticCode: SecStaticCode?
        let status = SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode)
        guard status == errSecSuccess, let code = staticCode else {
            throw PluginInstallError.signatureInvalid("无法读取代码签名（OSStatus \(status)）")
        }

        let validity = SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), nil)
        guard validity == errSecSuccess else {
            throw PluginInstallError.signatureInvalid("签名无效（OSStatus \(validity)）")
        }

        var information: CFDictionary?
        let copyStatus = SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
        guard copyStatus == errSecSuccess, let info = information as? [String: Any] else {
            return SignatureInfo(teamID: nil, isAdHoc: true)
        }

        let teamID = info[kSecCodeInfoTeamIdentifier as String] as? String
        let flags = (info[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        let isAdHoc = (flags & 0x2) != 0 || teamID == nil  // CS_ADHOC
        return SignatureInfo(teamID: teamID, isAdHoc: isAdHoc)
    }

    private static func isValidIdentifier(_ value: String) -> Bool {
        let pattern = "^[A-Za-z0-9][A-Za-z0-9.-]{2,127}$"
        return value.range(of: pattern, options: .regularExpression) != nil && value.contains(".")
    }
}
