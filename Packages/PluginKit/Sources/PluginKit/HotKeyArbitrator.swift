import Carbon
import Foundation
import PluginAPI

private let chassisHotKeySignature: OSType = 0x43687373  // 'Chss'
private let hotKeyEventType = EventTypeSpec(
    eventClass: OSType(kEventClassKeyboard),
    eventKind: UInt32(kEventHotKeyPressed)
)

private func chassisHotKeyHandler(
    callRef: EventHandlerCallRef?,
    event: EventRef?,
    userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }

    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr else { return status }

    let arbitrator = Unmanaged<HotKeyArbitrator>.fromOpaque(userData).takeUnretainedValue()
    let id = hotKeyID.id
    // Carbon 回调不在主线程：只投递标量 id，业务在主线程执行。
    DispatchQueue.main.async {
        MainActor.assumeIsolated {
            arbitrator.fire(id: id)
        }
    }
    return noErr
}

/// 全局快捷键仲裁。
///
/// 注册权必须在基座：全局快捷键是同一命名空间，各插件自行 `RegisterEventHotKey`
/// 时冲突表现为「某个功能莫名其妙不响应」（§6.4）。组合键内容仍由插件决定。
@MainActor
public final class HotKeyArbitrator {
    private struct Registration {
        let owner: String
        let spec: HotKeySpec
        let handler: @MainActor () -> Void
        let hotKeyRef: EventHotKeyRef?
    }

    private var registrations: [UInt32: Registration] = [:]
    private var specIndex: [HotKeySpec: UInt32] = [:]
    private var ownerIndex: [String: UInt32] = [:]
    private var nextID: UInt32 = 1
    private var eventHandler: EventHandlerRef?

    /// 冲突提示需要人类可读的插件名，由注册表注入。
    var titleProvider: ((String) -> String?)?

    public init() {}

    // MARK: - 注册

    public func register(_ spec: HotKeySpec, owner: String, handler: @escaping @MainActor () -> Void) throws {
        try validate(spec)

        if let existingID = specIndex[spec], let existing = registrations[existingID] {
            if existing.owner == owner {
                // 同一插件重复注册同一组合键：幂等，替换 handler 即可。
                registrations[existingID] = Registration(
                    owner: owner,
                    spec: spec,
                    handler: handler,
                    hotKeyRef: existing.hotKeyRef
                )
                return
            }
            throw HotKeyError.conflict(ownerTitle: title(for: existing.owner))
        }

        // 同一插件重复调用 register：先摘掉旧组合键，保证「一个插件一个快捷键」。
        if let oldID = ownerIndex[owner] {
            unregister(id: oldID)
        }

        let id = nextID
        nextID += 1
        let ref = try createCarbonHotKey(spec: spec, id: id)
        registrations[id] = Registration(owner: owner, spec: spec, handler: handler, hotKeyRef: ref)
        specIndex[spec] = id
        ownerIndex[owner] = id
    }

    /// 只换组合键，handler 不变；新键注册失败则保留旧键并抛错（原子性）。
    public func update(owner: String, to spec: HotKeySpec) throws {
        try validate(spec)

        guard let currentID = ownerIndex[owner], let current = registrations[currentID] else {
            throw HotKeyError.invalid("该插件尚未注册任何快捷键")
        }
        if current.spec == spec { return }

        if let existingID = specIndex[spec], existingID != currentID, let existing = registrations[existingID] {
            throw HotKeyError.conflict(ownerTitle: title(for: existing.owner))
        }

        // 先注册新键：失败时旧键原地保留。
        let newID = nextID
        let ref = try createCarbonHotKey(spec: spec, id: newID)
        nextID += 1

        unregister(id: currentID)
        registrations[newID] = Registration(owner: owner, spec: spec, handler: current.handler, hotKeyRef: ref)
        specIndex[spec] = newID
        ownerIndex[owner] = newID
    }

    public func unregisterAll(owner: String) {
        guard let id = ownerIndex[owner] else { return }
        unregister(id: id)
    }

    public func unregister(owner: String) {
        unregisterAll(owner: owner)
    }

    // MARK: - 查询

    public func availability(of spec: HotKeySpec, requester: String) -> HotKeyAvailability {
        if let problem = validationProblem(spec) {
            return .invalid(reason: problem)
        }
        if let id = specIndex[spec], let existing = registrations[id], existing.owner != requester {
            return .takenByPlugin(ownerID: existing.owner, title: title(for: existing.owner))
        }
        return .available
    }

    public func ownerDescription(of spec: HotKeySpec) -> String? {
        guard let id = specIndex[spec], let existing = registrations[id] else { return nil }
        return title(for: existing.owner)
    }

    // MARK: - 内部

    func fire(id: UInt32) {
        registrations[id]?.handler()
    }

    private func title(for owner: String) -> String {
        titleProvider?(owner) ?? owner
    }

    private func unregister(id: UInt32) {
        guard let registration = registrations.removeValue(forKey: id) else { return }
        specIndex.removeValue(forKey: registration.spec)
        if ownerIndex[registration.owner] == id {
            ownerIndex.removeValue(forKey: registration.owner)
        }
        if let ref = registration.hotKeyRef {
            UnregisterEventHotKey(ref)
        }
    }

    private func createCarbonHotKey(spec: HotKeySpec, id: UInt32) throws -> EventHotKeyRef? {
        installEventHandlerIfNeeded()

        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: chassisHotKeySignature, id: id)
        let status = RegisterEventHotKey(
            spec.keyCode,
            carbonModifiers(from: spec.modifiers),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        guard status == noErr, ref != nil else {
            // 系统或其他应用已占用该组合键。
            throw HotKeyError.reservedBySystem
        }
        return ref
    }

    private func installEventHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var spec = hotKeyEventType
        InstallEventHandler(
            GetApplicationEventTarget(),
            chassisHotKeyHandler,
            1,
            &spec,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
    }

    private func carbonModifiers(from modifiers: HotKeyModifiers) -> UInt32 {
        var result: UInt32 = 0
        if modifiers.contains(.command) { result |= UInt32(cmdKey) }
        if modifiers.contains(.option) { result |= UInt32(optionKey) }
        if modifiers.contains(.control) { result |= UInt32(controlKey) }
        if modifiers.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }

    private func validate(_ spec: HotKeySpec) throws {
        if let problem = validationProblem(spec) {
            throw HotKeyError.invalid(problem)
        }
    }

    private func validationProblem(_ spec: HotKeySpec) -> String? {
        if spec.modifiers.isEmpty {
            return "快捷键必须包含至少一个修饰键"
        }
        if Self.modifierKeyCodes.contains(spec.keyCode) {
            return "修饰键不能单独作为快捷键"
        }
        return nil
    }

    /// 纯修饰键的虚拟键码（Command / Shift / CapsLock / Option / Control / Fn / 左右变体）。
    private static let modifierKeyCodes: Set<UInt32> = [0x36, 0x37, 0x38, 0x39, 0x3A, 0x3B, 0x3C, 0x3D, 0x3E, 0x3F]
}
