import Foundation

public enum LogLevel: Sendable {
    case debug
    case info
    case warning
    case error
}

/// 刻意不叫 Logger：插件一旦 import os，两个 Logger 会撞名。
/// debug 仅内部构建输出；禁止记录窗口标题、文件路径、剪贴板、用户输入。
@MainActor
public protocol PluginLogger {
    func log(_ level: LogLevel, _ message: @autoclosure () -> String)
    func debug(_ message: @autoclosure () -> String)
    func info(_ message: @autoclosure () -> String)
    func warning(_ message: @autoclosure () -> String)
    func error(_ message: @autoclosure () -> String)
}
