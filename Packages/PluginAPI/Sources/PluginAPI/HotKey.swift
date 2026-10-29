import Foundation

/// Codable 是必需的：插件要把它存进自己的 PluginStore。
public struct HotKeySpec: Hashable, Codable, Sendable {
    /// 虚拟键码（kVK_*）。
    public let keyCode: UInt32
    /// 必须至少包含一个修饰键。
    public let modifiers: HotKeyModifiers

    public init(keyCode: UInt32, modifiers: HotKeyModifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
}

/// 修饰键集合。同样必须 Codable——它随 HotKeySpec 一起落盘。
public struct HotKeyModifiers: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static let command = HotKeyModifiers(rawValue: 1 << 0)
    public static let option = HotKeyModifiers(rawValue: 1 << 1)
    public static let control = HotKeyModifiers(rawValue: 1 << 2)
    public static let shift = HotKeyModifiers(rawValue: 1 << 3)
}

public enum HotKeyAvailability: Sendable {
    case available
    case takenByPlugin(ownerID: String, title: String)
    /// 被系统或其他应用占用。
    case takenBySystem
    /// 无修饰键、纯修饰键、无效组合。
    case invalid(reason: String)
}

public enum HotKeyError: Error {
    case conflict(ownerTitle: String)
    case reservedBySystem
    case invalid(String)
}
