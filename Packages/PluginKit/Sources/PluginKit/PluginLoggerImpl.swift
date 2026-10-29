import Foundation
import PluginAPI
import os

/// 带 pluginID 前缀的日志实现。
///
/// 禁止记录窗口标题、文件路径、剪贴板、用户输入——诊断包会被用户导出并公开贴出（§6.8）。
@MainActor
final class PluginLoggerImpl: PluginLogger {
    private let pluginID: String
    private let subsystem: String
    private let store: LogStore
    private let osLogger: os.Logger

    init(pluginID: String, subsystem: String, store: LogStore) {
        self.pluginID = pluginID
        self.subsystem = subsystem
        self.store = store
        self.osLogger = os.Logger(subsystem: subsystem, category: pluginID)
    }

    func log(_ level: LogLevel, _ message: @autoclosure () -> String) {
        #if !DEBUG
        // Release 下 debug 不落盘（§6.8）：连字符串插值都不应该发生。
        if case .debug = level { return }
        #endif
        let text = message()
        store.append(level: level, pluginID: pluginID, message: text)
        switch level {
        case .debug:
            osLogger.debug("\(text, privacy: .public)")
        case .info:
            osLogger.info("\(text, privacy: .public)")
        case .warning:
            osLogger.warning("\(text, privacy: .public)")
        case .error:
            osLogger.error("\(text, privacy: .public)")
        }
    }

    func debug(_ message: @autoclosure () -> String) { log(.debug, message()) }
    func info(_ message: @autoclosure () -> String) { log(.info, message()) }
    func warning(_ message: @autoclosure () -> String) { log(.warning, message()) }
    func error(_ message: @autoclosure () -> String) { log(.error, message()) }
}

/// 基座自身日志（无 pluginID）。
@MainActor
public final class HostLogger: PluginLogger {
    private let inner: PluginLoggerImpl

    public init(subsystem: String, store: LogStore) {
        inner = PluginLoggerImpl(pluginID: "host", subsystem: subsystem, store: store)
    }

    public func log(_ level: LogLevel, _ message: @autoclosure () -> String) { inner.log(level, message()) }
    public func debug(_ message: @autoclosure () -> String) { inner.debug(message()) }
    public func info(_ message: @autoclosure () -> String) { inner.info(message()) }
    public func warning(_ message: @autoclosure () -> String) { inner.warning(message()) }
    public func error(_ message: @autoclosure () -> String) { inner.error(message()) }
}
