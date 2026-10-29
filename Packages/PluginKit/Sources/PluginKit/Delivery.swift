import AtomicsShim
import Foundation
import PluginAPI

/// 把值从 tap 线程 / 后台线程投递到 Main Actor。
///
/// 这是 tap 线程回调尾部**唯一**允许的队列跳转（§6.3）：只投递值类型，不阻塞、不加锁。
/// 取消标志用 `AtomicFlag`，因此 tap 线程可以无锁判断「这条订阅是否已失效」。
final class DeliveryBox<Value: Sendable>: @unchecked Sendable {
    private let cancelled = AtomicFlag(false)
    private let handler: @MainActor (Value) -> Void

    init(_ handler: @escaping @MainActor (Value) -> Void) {
        self.handler = handler
    }

    func dispatch(_ value: Value) {
        if cancelled.value { return }
        DispatchQueue.main.async { [self] in
            guard !cancelled.value else { return }
            MainActor.assumeIsolated {
                handler(value)
            }
        }
    }

    func cancel() {
        cancelled.value = true
    }
}

/// 输入源降级广播器：tap 线程/后台线程 → Main Actor。
final class InterruptionRelay: @unchecked Sendable {
    private let onMain: @MainActor (InputInterruption) -> Void

    init(_ onMain: @escaping @MainActor (InputInterruption) -> Void) {
        self.onMain = onMain
    }

    func send(_ interruption: InputInterruption) {
        DispatchQueue.main.async { [self] in
            MainActor.assumeIsolated {
                onMain(interruption)
            }
        }
    }
}
