import Foundation
import PluginAPI
import os

/// 诊断包用的环形日志缓冲。容量固定 500 条，超出丢弃最旧一条。
///
/// 这里用锁是安全的：所有写入都发生在 Main Actor（插件日志）或基座内部，
/// 绝不在 tap 线程调用——§7 的禁令只针对 tap 线程。
public final class LogStore: @unchecked Sendable {
    public struct Entry {
        public let date: Date
        public let level: LogLevel
        public let pluginID: String?
        public let message: String
    }

    private let lock = NSLock()
    private var buffer: [Entry] = []
    private let capacity = 500

    public init() {}

    func append(level: LogLevel, pluginID: String?, message: String) {
        lock.lock()
        buffer.append(Entry(date: Date(), level: level, pluginID: pluginID, message: message))
        if buffer.count > capacity {
            buffer.removeFirst(buffer.count - capacity)
        }
        lock.unlock()
    }

    public func snapshot(limit: Int = 100) -> [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return Array(buffer.suffix(limit))
    }
}
