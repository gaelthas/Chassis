import Foundation
import Security

/// 应用身份的唯一来源：全部读 Bundle，代码中不出现字面量（ADR-20）。
/// 版本号来自构建设置的 `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`。
public enum AppIdentity {
    public static var bundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? "unknown.bundle"
    }

    public static var name: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? ProcessInfo.processInfo.processName
    }

    public static var version: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.0.0"
    }

    public static var build: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "0"
    }

    public static var copyright: String {
        (Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String) ?? ""
    }

    public static var summary: String {
        (Bundle.main.object(forInfoDictionaryKey: "ChassisSummary") as? String)
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleGetInfoString") as? String)
            ?? ""
    }

    /// 基座自身的签名 Team ID；用于「只信任同 Team 插件」的默认策略。
    public static var teamID: String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var information: CFDictionary?
        // SecCode 与 SecStaticCode 在 Swift 中是两个类型，底层同为 CFType。
        let staticCode = unsafeBitCast(code, to: SecStaticCode.self)
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let info = information as? [String: Any] else {
            return nil
        }
        return info[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// 关于页展示版本用。
    public static var versionDisplay: String {
        "\(version) (\(build))"
    }
}
