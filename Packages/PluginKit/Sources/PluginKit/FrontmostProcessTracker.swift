import AppKit
import AtomicsShim
import Foundation

/// 前台进程的原子快照。
///
/// 点击会改变前台应用，事后再查 `NSWorkspace.shared.frontmostApplication`
/// 得到的是「新世界」。因此基座在主线程监听激活通知，把 pid 写进原子整数；
/// tap 线程构造 `ClickContext` 时只读这个标量（§4.4.3）。
@MainActor
final class FrontmostProcessTracker {
    let slot: OpaquePointer
    private var observer: NSObjectProtocol?

    init?() {
        guard let slot = ch_atomic_int_create(0) else { return nil }
        self.slot = slot
        update()
    }

    // 进程级对象，随应用退出回收；不做 deinit 清理，避免 nonisolated deinit 访问隔离属性。

    func start() {
        guard observer == nil else { return }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // 通知回调已在主队列，但类型上是 nonisolated 闭包，需显式跳回 Main Actor。
            MainActor.assumeIsolated {
                self?.update()
            }
        }
    }

    private func update() {
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        ch_atomic_int_store(slot, Int(pid))
    }
}
