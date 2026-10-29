import CoreGraphics

/// 阶段一的声明式预筛。`requiredFlags` 是**包含语义**：事件 flags 必须 ⊇ 此集合，
/// 因此 `.maskCommand` 同时命中 ⌘Q 与 ⌘⇧Q。要精确匹配请在 handler 里自行比对。
public struct KeyFilter: Sendable {
    public let keyCodes: Set<Int64>
    public let requiredFlags: CGEventFlags

    public init(keyCodes: Set<Int64>, requiredFlags: CGEventFlags = []) {
        self.keyCodes = keyCodes
        self.requiredFlags = requiredFlags
    }

    /// tap 线程上使用的判定：只做集合查找与位运算。
    @inline(__always)
    func matches(keyCode: Int64, flags: CGEventFlags) -> Bool {
        guard keyCodes.contains(keyCode) else { return false }
        guard !requiredFlags.isEmpty else { return true }
        return flags.isSuperset(of: requiredFlags)
    }
}

/// 键盘事件的类别。
///
/// 初版 `KeyEvent` 只有 keyCode/flags/isRepeat，无法区分「按下」与「抬起」，
/// 导致「按住 ⌘Q 才退出」「松开 ⌥ 才提交切换」这类需求无法实现（只能自建 tap）。
/// 这是对附录 A 的**增量**补充，不改变既有调用点。
public enum KeyEventKind: Sendable {
    case keyDown
    case keyUp
    /// 修饰键状态变化（如单独按/放 ⌥、⌘）。
    case flagsChanged
}

/// 投递到 Main Actor 的键盘事件值。不含任何对象。
public struct KeyEvent: Sendable {
    public let keyCode: Int64
    public let flags: CGEventFlags
    public let isRepeat: Bool
    public let kind: KeyEventKind

    public init(keyCode: Int64, flags: CGEventFlags, isRepeat: Bool, kind: KeyEventKind = .keyDown) {
        self.keyCode = keyCode
        self.flags = flags
        self.isRepeat = isRepeat
        self.kind = kind
    }
}

/// 阶段二的返回值。仅需要吞事件的功能实现它。
public enum KeyIntercept: Sendable {
    case passthrough
    case consume
}
