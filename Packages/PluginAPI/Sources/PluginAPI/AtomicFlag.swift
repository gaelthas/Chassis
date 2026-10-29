import AtomicsShim
import Foundation

/// tap 线程与 Main Actor 之间唯一允许共享状态的载体。
///
/// 具体类型而非协议：tap 线程预算以微秒计，动态派发不可接受。
/// 实现为纯原子指令（C11 `_Atomic`），无锁、无堆分配（一次 malloc 在构造期完成）、无 ARC。
/// macOS 14 目标下没有 `Synchronization.Atomic`（15+），`os_unfair_lock` 属于锁，两者都不可用。
public final class AtomicFlag: @unchecked Sendable {
    // C 侧是不透明结构体，Swift 以 OpaquePointer 持有。
    private let storage: OpaquePointer

    public init(_ initial: Bool = false) {
        guard let created = ch_atomic_flag_create(initial) else {
            fatalError("AtomicsShim: 无法分配原子标志")
        }
        storage = created
    }

    deinit {
        ch_atomic_flag_destroy(storage)
    }

    public var value: Bool {
        get { ch_atomic_flag_load(storage) }
        set { ch_atomic_flag_store(storage, newValue) }
    }
}
