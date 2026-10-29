import AppKit
import Foundation
import PluginABI
import PluginAPI
import SwiftUI

/// 外部插件加载：`dlopen` → ABI 版本协商 → 适配成内部 `FeaturePlugin`。
///
/// 动态库一旦加载就不再卸载（`dlclose` 对 Swift 运行时不安全），
/// 因此「卸载插件」只是移出注册表 + 删除文件，真正释放发生在退出应用时。
@MainActor
public final class ExternalPluginLoader {
    public enum LoadError: LocalizedError {
        case manifestMissing(String)
        case libraryMissing(String)
        case openFailed(String)
        case entryMissing
        case abiMismatch(UInt32)
        case createFailed
        case activateFailed(Int32)

        public var errorDescription: String? {
            switch self {
            case let .manifestMissing(path): return "缺少清单：\(path)"
            case let .libraryMissing(path): return "缺少动态库：\(path)"
            case let .openFailed(detail): return "无法加载动态库：\(detail)"
            case .entryMissing: return "缺少 chassis_plugin_entry 导出符号"
            case let .abiMismatch(version): return "插件 ABI 版本 \(version) 不受支持"
            case .createFailed: return "插件 create() 返回空"
            case let .activateFailed(code): return "插件 activate 返回 \(code)"
            }
        }
    }

    private struct LoadedLibrary {
        let handle: UnsafeMutableRawPointer
        let vtable: UnsafeMutablePointer<chassis_plugin_v1>
    }

    private let hostVersion: String
    private let logStore: LogStore
    private var libraries: [String: LoadedLibrary] = [:]

    public init(hostVersion: String, logStore: LogStore) {
        self.hostVersion = hostVersion
        self.logStore = logStore
    }

    // MARK: - 注册

    /// 只为已安装记录生成注册项；清单解析失败直接跳过并记日志（不影响其他插件）。
    public func registrations(from records: [InstalledPluginRecord]) -> [ExternalPluginRegistration] {
        records.compactMap { record in
            do {
                let package = try readPackage(record)
                let manifest = makeManifest(package: package, bundlePath: record.path)
                let info = ExternalPluginInfo(
                    version: record.version,
                    teamID: record.teamID,
                    installedAt: record.installedAt,
                    path: record.path
                )
                return ExternalPluginRegistration(manifest: manifest, info: info) { [weak self] in
                    guard let self else { throw LoadError.openFailed("loader released") }
                    return try self.instantiate(record: record, package: package)
                }
            } catch {
                logStore.append(level: .error, pluginID: record.id, message: "外部插件清单读取失败：\(error)")
                return nil
            }
        }
    }

    public func readPackage(_ record: InstalledPluginRecord) throws -> PluginPackageManifest {
        let bundleURL = URL(fileURLWithPath: record.path)
        guard let url = PluginInstaller.manifestURL(in: bundleURL) else {
            throw LoadError.manifestMissing(bundleURL.path)
        }
        return try JSONDecoder().decode(PluginPackageManifest.self, from: Data(contentsOf: url))
    }

    public func makeManifest(package: PluginPackageManifest, bundlePath: String) -> PluginManifest {
        let capabilities = package.capabilitySet
        return PluginManifest(
            id: package.id,
            version: package.version,
            minHostVersion: package.minHostVersion,
            // 外部清单自带文案：用字符串构造 key，查不到时回退为原文（verbatim 效果）。
            title: LocalizedStringKey(package.title.resolve()),
            summary: LocalizedStringKey(package.summary.resolve()),
            iconSystemName: package.iconSystemName,
            requiredCapabilities: capabilities.required,
            optionalCapabilities: capabilities.optional,
            resourceBundle: Bundle(path: bundlePath) ?? .main
        )
    }

    // MARK: - 实例化

    private func instantiate(record: InstalledPluginRecord, package: PluginPackageManifest) throws -> any FeaturePlugin {
        let library = try loadLibrary(record: record)

        guard library.vtable.pointee.struct_size >= MemoryLayout<chassis_plugin_v1>.size else {
            throw LoadError.abiMismatch(0)
        }
        guard let activate = library.vtable.pointee.activate,
              let deactivate = library.vtable.pointee.deactivate else {
            throw LoadError.entryMissing
        }
        _ = activate
        _ = deactivate

        return ExternalPluginAdapter(
            manifest: makeManifest(package: package, bundlePath: record.path),
            vtable: library.vtable
        )
    }

    private func loadLibrary(record: InstalledPluginRecord) throws -> LoadedLibrary {
        if let cached = libraries[record.path] { return cached }

        let bundleURL = URL(fileURLWithPath: record.path)
        let executableName = (Bundle(url: bundleURL)?.infoDictionary?["CFBundleExecutable"] as? String)
            ?? record.id.split(separator: ".").last.map(String.init)
            ?? record.id
        let candidates = [
            bundleURL.appendingPathComponent("Contents/MacOS/\(executableName)"),
            bundleURL.appendingPathComponent("Contents/MacOS/Plugin"),
        ]
        guard let libraryURL = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            throw LoadError.libraryMissing(candidates.map(\.path).joined(separator: " | "))
        }

        guard let handle = dlopen(libraryURL.path, RTLD_NOW | RTLD_LOCAL) else {
            let message = String(cString: dlerror() ?? UnsafeMutablePointer<CChar>.allocate(capacity: 0))
            throw LoadError.openFailed(message)
        }
        guard let symbol = dlsym(handle, "chassis_plugin_entry") else {
            dlclose(handle)
            throw LoadError.entryMissing
        }

        typealias Entry = @convention(c) (UInt32) -> UnsafeMutablePointer<chassis_plugin_v1>?
        let entry = unsafeBitCast(symbol, to: Entry.self)
        guard let vtable = entry(UInt32(CHASSIS_PLUGIN_ABI_VERSION)) else {
            dlclose(handle)
            throw LoadError.abiMismatch(0)
        }

        let loaded = LoadedLibrary(handle: handle, vtable: vtable)
        libraries[record.path] = loaded
        logStore.append(level: .info, pluginID: record.id, message: "外部插件动态库已加载")
        return loaded
    }
}

// MARK: - 适配器

@MainActor
final class ExternalPluginAdapter: FeaturePlugin {
    /// 动态插件没有编译期清单；基座用的是注册项里的 manifest，这个静态值只为满足协议。
    static var manifest: PluginManifest { fatalError("外部插件不支持静态 manifest") }

    let manifest: PluginManifest
    private let vtable: UnsafeMutablePointer<chassis_plugin_v1>
    private var instance: UnsafeMutableRawPointer?
    private var services: UnsafeMutablePointer<chassis_host_services_v1>?
    private var box: ExternalServicesBox?

    /// 协议要求；动态插件只能由 loader 构造。
    init() { fatalError("外部插件请通过 ExternalPluginLoader 创建") }

    init(manifest: PluginManifest, vtable: UnsafeMutablePointer<chassis_plugin_v1>) {
        self.manifest = manifest
        self.vtable = vtable
    }

    func activate(context: PluginContext) throws {
        guard let create = vtable.pointee.create, let instance = create() else {
            throw ExternalPluginLoader.LoadError.createFailed
        }
        self.instance = instance

        let box = ExternalServicesBox(pluginID: context.pluginID, hostVersion: context.hostVersion, context: context)
        self.box = box

        let services = UnsafeMutablePointer<chassis_host_services_v1>.allocate(capacity: 1)
        services.initialize(to: ExternalServicesFactory.make(box: box))
        self.services = services

        let status = vtable.pointee.activate?(instance, services) ?? -1
        guard status == 0 else {
            vtable.pointee.destroy?(instance)
            teardown()
            throw ExternalPluginLoader.LoadError.activateFailed(status)
        }
    }

    func deactivate() {
        guard let instance else { return }
        vtable.pointee.deactivate?(instance)
        vtable.pointee.destroy?(instance)
        teardown()
    }

    func makeSettingsView() -> AnyView {
        guard let instance, let makeView = vtable.pointee.make_settings_view, let raw = makeView(instance) else {
            return AnyView(Text(verbatim: "该插件没有提供设置视图"))
        }
        let controller = Unmanaged<NSViewController>.fromOpaque(raw).takeRetainedValue()
        return AnyView(ExternalSettingsViewHost(controller: controller))
    }

    private func teardown() {
        box?.cancelAll()
        instance = nil
        if let services {
            services.deinitialize(count: 1)
            services.deallocate()
        }
        services = nil
        box = nil
    }
}

/// 把外部插件返回的 `NSViewController` 包成 SwiftUI 视图。
struct ExternalSettingsViewHost: NSViewRepresentable {
    let controller: NSViewController

    func makeNSView(context: Context) -> NSView {
        let view = controller.view
        view.translatesAutoresizingMaskIntoConstraints = false
        // 直接返回控制器的 view：所有权在本视图上，避免再套一层容器导致尺寸塌陷。
        let container = NSView()
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
