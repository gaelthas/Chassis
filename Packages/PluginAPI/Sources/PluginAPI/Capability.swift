import Foundation

/// 三项系统授权。通知不在此列——通知被拒时插件应照常工作（设计文档 §6.8）。
public enum Capability: String, Hashable, CaseIterable, Sendable {
    case accessibility
    case inputMonitoring
    case screenCapture
}
