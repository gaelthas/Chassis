import AppKit
import PluginAPI
import SwiftUI

/// 录键控件：捕获按键、过滤无效组合、实时冲突校验、提交失败自动回滚。
///
/// 放在 `PluginSupport` 而不是 `PluginAPI`：文档要求基座提供该控件，但 `PluginAPI` 必须保持零实现；
/// 也不放 `PluginKit`（插件无法依赖）。它只做 UI，不持有任何全局资源。
public struct HotKeyRecorder: View {
    @Binding private var spec: HotKeySpec
    private let availability: (HotKeySpec) -> HotKeyAvailability
    private let onCommit: (HotKeySpec) throws -> Void

    @State private var isRecording = false
    @State private var notice: String?
    @State private var monitor: Any?

    public init(
        spec: Binding<HotKeySpec>,
        availability: @escaping (HotKeySpec) -> HotKeyAvailability,
        onCommit: @escaping (HotKeySpec) throws -> Void
    ) {
        _spec = spec
        self.availability = availability
        self.onCommit = onCommit
    }

    public var body: some View {
        HStack(spacing: 10) {
            Button {
                isRecording.toggle()
            } label: {
                Text(isRecording ? "…" : Self.display(spec))
                    .font(.body.monospaced())
                    .frame(minWidth: 84)
            }
            .buttonStyle(.bordered)
            .help(isRecording ? "按下组合键，Esc 取消" : "点击后按下新的组合键")

            if let notice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .onDisappear { stopRecording() }
        .onChange(of: isRecording) { _, recording in
            if recording { startRecording() } else { stopRecording() }
        }
    }

    // MARK: - 录键

    private func startRecording() {
        notice = nil
        stopMonitor()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            handle(event)
        }
    }

    private func stopRecording() {
        isRecording = false
        stopMonitor()
    }

    private func stopMonitor() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        if event.keyCode == 0x35 {  // Esc
            stopRecording()
            return nil
        }

        let modifiers = Self.modifiers(from: event.modifierFlags)
        guard !modifiers.isEmpty else {
            // 纯字母没有修饰键：无效组合，不提交，但也不放行（避免误触输入到别处）。
            notice = Self.invalidModifiersNotice
            return nil
        }

        let candidate = HotKeySpec(keyCode: UInt32(event.keyCode), modifiers: modifiers)

        switch availability(candidate) {
        case .available:
            do {
                try onCommit(candidate)
                spec = candidate
                notice = nil
                stopRecording()
            } catch {
                notice = Self.describe(error)
                stopRecording()
            }
        case let .takenByPlugin(_, title):
            notice = Self.occupiedNotice(title)
        case .takenBySystem:
            notice = Self.systemOccupiedNotice
        case let .invalid(reason):
            notice = reason
        }
        return nil
    }

    // MARK: - 展示

    static func modifiers(from flags: NSEvent.ModifierFlags) -> HotKeyModifiers {
        var modifiers: HotKeyModifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        return modifiers
    }

    public static func display(_ spec: HotKeySpec) -> String {
        var text = ""
        if spec.modifiers.contains(.control) { text += "⌃" }
        if spec.modifiers.contains(.option) { text += "⌥" }
        if spec.modifiers.contains(.shift) { text += "⇧" }
        if spec.modifiers.contains(.command) { text += "⌘" }
        return text + keyName(spec.keyCode)
    }

    private static let invalidModifiersNotice = "需要至少一个修饰键"
    private static let systemOccupiedNotice = "该组合键已被系统占用"

    private static func occupiedNotice(_ title: String) -> String {
        "已被「\(title)」占用"
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case let HotKeyError.conflict(ownerTitle):
            return occupiedNotice(ownerTitle)
        case HotKeyError.reservedBySystem:
            return systemOccupiedNotice
        case let HotKeyError.invalid(reason):
            return reason
        default:
            return String(describing: error)
        }
    }

    private static func keyName(_ keyCode: UInt32) -> String {
        keyNames[keyCode] ?? "Key\(keyCode)"
    }

    private static let keyNames: [UInt32: String] = [
        0x00: "A", 0x01: "S", 0x02: "D", 0x03: "F", 0x04: "H", 0x05: "G", 0x06: "Z", 0x07: "X",
        0x08: "C", 0x09: "V", 0x0B: "B", 0x0C: "Q", 0x0D: "W", 0x0E: "E", 0x0F: "R", 0x10: "Y",
        0x11: "T", 0x12: "1", 0x13: "2", 0x14: "3", 0x15: "4", 0x16: "6", 0x17: "5", 0x18: "=",
        0x19: "9", 0x1A: "7", 0x1B: "-", 0x1C: "8", 0x1D: "0", 0x1E: "]", 0x1F: "O", 0x20: "U",
        0x21: "[", 0x22: "I", 0x23: "P", 0x25: "L", 0x26: "J", 0x27: "'", 0x28: "K", 0x29: ";",
        0x2A: "\\", 0x2B: ",", 0x2C: "/", 0x2D: "N", 0x2E: "M", 0x2F: ".", 0x32: "`",
        0x24: "⏎", 0x30: "⇥", 0x31: "Space", 0x33: "⌫", 0x35: "⎋",
        0x7B: "←", 0x7C: "→", 0x7D: "↓", 0x7E: "↑",
        0x7A: "F1", 0x78: "F2", 0x63: "F3", 0x76: "F4", 0x60: "F5", 0x61: "F6",
        0x62: "F7", 0x64: "F8", 0x65: "F9", 0x6D: "F10", 0x67: "F11", 0x6F: "F12",
    ]
}
