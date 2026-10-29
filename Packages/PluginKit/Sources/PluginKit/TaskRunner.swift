import Foundation
import PluginAPI

/// `performBackground` 的唯一实现：单一串行队列。
///
/// 串行是有意为之：多个插件同时查询同一个卡住的应用时，串行队列让它们排队，
/// 而不是并发堆积几十个阻塞线程。代价是吞吐，收益是系统整体可预测（§7）。
@MainActor
public final class TaskRunner {
    private let queue: DispatchQueue

    public init(label: String = "com.gaelthas.chassis.background") {
        queue = DispatchQueue(label: label, qos: .userInitiated)
    }

    public func perform<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: try work())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
