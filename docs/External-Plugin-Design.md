# 外部插件包与逐插件授权 · 设计

> 状态：**P0 / P1 / P2 已实现**（逐插件授权、包格式与安装流程、C ABI 动态加载、示例插件）
> 实现位置：`Packages/PluginAPI` + `Packages/PluginKit`（`PluginConsentStore` / `PluginInstaller` / `ExternalPluginLoader`）、
> `Packages/PluginABI`（纯 C）、`HostApp/Views`（安装与授权 UI）、
> 示例插件 `Chassis-Plugins/Examples/HelloPlugin`、校验工具 `Tools/PluginCheck`
> 前置文档：`Host-Architecture-Design.md`（v2.2）、`Chassis-Plugins/docs/Plugin-Development-Guide.md`
> 本文回答三个问题：插件怎么打包、基座怎么装、权限怎么在基座内按插件收口

---

## 0. 需求（来自产品侧）

1. 插件可以**打包分发给第三方**，由用户导入基座安装。
2. 安装后**不需要用户再走一遍系统授权**（TCC 只对基座授权一次）。
3. **基座对每个插件单独授权**，由基座控制插件能用哪些能力。
4. 安装完成的插件默认**未启用**，需用户手动开启。
5. 点击插件行的**设置**，进入插件自己提供的设置页。

需求 2 与 3 决定了架构主线：**插件必须与基座同进程运行**（TCC 不可转授，只有同进程才能共享基座已获得的授权），
而「按插件授权」只能由基座自己在 API 层做**能力门控**，不能指望系统。

---

## 1. 诚实的前提：这推翻了原来的三条 ADR

| 原决策 | 原因 | 现在必须改成 | 代价 |
|---|---|---|---|
| ADR-1 进程内插件 | 内部自研、同 Team 签名 | **保留进程内**，但面向外部 | 插件可绕过 API 直接调系统接口；插件崩溃带走基座 |
| ADR-2 静态链接 | 无热更新需求、不触发 Library Validation | **动态加载** | 需 `disable-library-validation` 或限定同 Team 签名；需 API 稳定化 |
| ADR-19 威胁模型 = 内部开发者写错 | 同仓库、同审查 | **威胁模型换成不可信代码** | 现有「编译期隔离」全部失效，只剩签名 + 用户同意 + 审查 |

必须在文档与 UI 里如实说明：**同进程插件 = 与基座等权**。
「基座按插件授权」是**门控**（不给 API、不投递事件、不注册快捷键），不是沙箱。
插件若自行 `dlopen`、直接调 AX/CG，基座无法阻止——这是「授权不用重新做」的必然代价。

---

## 2. 插件包格式 `.chassisplugin`

目录型 bundle（便于签名与资源本地化）：

```
MyPlugin.chassisplugin/
├── Contents/
│   ├── Info.plist                 # bundle 元信息（CFBundleIdentifier / 版本 / 最低系统）
│   ├── MacOS/
│   │   └── MyPlugin               # 动态库（MH_DYLIB，C ABI 入口，见 §4）
│   ├── Resources/
│   │   ├── manifest.json          # 基座读取的插件清单（见 §2.1）
│   │   ├── zh-Hans.lproj/
│   │   └── en.lproj/
│   ├── _CodeSignature/            # codesign 生成
│   └── embedded.provisionprofile  # 可选
└── （可通过 ditto/zip 保持签名分发）
```

### 2.1 `manifest.json`

```json
{
  "schema": 1,
  "id": "com.example.plugin.window-tools",
  "version": "1.0.0",
  "minHostVersion": "1.0.0",
  "apiVersion": 1,
  "title": { "zh-Hans": "窗口工具", "en": "Window Tools" },
  "summary": { "zh-Hans": "一句话说明", "en": "One line" },
  "iconSystemName": "macwindow.on.rectangle",
  "requiredCapabilities": ["accessibility"],
  "optionalCapabilities": ["screenCapture"],
  "principalClass": "MyPlugin.PluginEntry",
  "vendor": "Example Inc.",
  "supportURL": "https://example.com/support"
}
```

- `apiVersion`：**唯一的兼容判据**。基座只加载自己支持的版本，不做任何猜测性兼容。
- `title`/`summary` 用字典而不是 `.strings`：基座在**加载代码之前**就要展示清单，
  不能依赖插件 bundle 里的本地化文件（那个可以伪造，且加载代码本身有风险）。
- 清单里的能力声明是**申请**，实际授予由基座决定（§5）。

---

## 3. 安装流程

```
用户点「安装插件…」→ NSOpenPanel(.chassisplugin)
   ↓
① 结构校验：Info.plist / manifest.json / 动态库存在，schema/apiVersion 支持
② 签名校验：codesign --verify --deep --strict + Team ID 白名单 + 可选公证票据
③ 兼容校验：minHostVersion ≤ hostVersion；id 未与内置插件冲突；id 已安装则视为升级
④ 隔离展示：弹出确认页，列出 名称 / 版本 / 发行方 / 声明的权限 / 「与基座同进程」警告
   ↓ 用户确认
⑤ 复制到 ~/Library/Application Support/com.gaelthas.chassis/Plugins/<id>/
⑥ 写入注册表（HostStore）：id / 版本 / 路径 / TeamID / 安装时间 / 内容指纹
   ↓
⑦ 出现在插件列表，状态 = disabled（默认关闭，遵循 P2：未启用不申请、不加载）
   ↓
⑧ 用户「启用」→ 逐权限确认（§5）→ 加载动态库 → activate
```

要点：

- **安装不等于启用**，也不等于加载代码。列表渲染只用 `manifest.json`，不需要 dlopen。
- 卸载：从列表移除 + 删除注册表项；**文件移到废纸篓**（可恢复），不做静默删除。
- 升级：id 相同视为替换，保留该插件的 enabled 状态与配置（配置按 id 隔离，天然兼容）。
- 内置插件（`PluginCatalog` 静态注册）与外部插件在列表中的差异只有「来源」标记，其余行为一致。

---

## 4. 加载模型

### 4.1 为什么是 C ABI

Swit 的 `protocol` 跨动态库没有稳定 ABI：插件用另一个 Xcode/Swift 版本编译就会崩，
而 `BUILD_LIBRARY_FOR_DISTRIBUTION` 只能解决「同 Team、允许 library evolution」的库，
解决不了「第三方用任意工具链编译」的问题。C ABI 是唯一跨工具链稳定的边界。

### 4.2 边界定义（`PluginABI`，纯 C）

```c
// chassis_plugin.h
typedef struct chassis_plugin_v1 {
    uint32_t struct_size;                 // 版本演进：读方按自身大小截断
    const char *manifest_json;            // UTF-8，与 manifest.json 同构
    void *(*create)(void);                // 返回插件实例（保留引用）
    void (*destroy)(void *instance);
    int32_t (*activate)(void *instance, chassis_host_services *services);
    void (*deactivate)(void *instance);
    void *(*make_settings_view)(void *instance);   // 返回 NSViewController*（已在主线程）
} chassis_plugin_v1;

// 插件侧唯一必须导出的符号
chassis_plugin_v1 *chassis_plugin_entry(uint32_t host_api_version);
```

`chassis_host_services` 是一张函数指针表，由基座填充：订阅输入、注册快捷键、发通知、
读配置、写日志、后台执行、查询权限。**插件永远拿不到 Objective-C/Swift 对象**，
只有不透明句柄 + 回调，跨线程边界天然明确。

### 4.3 宿主侧适配

- `DynamicPlugin`：包装 C 句柄，对外实现内部 `FeaturePlugin` 协议（manifest 由 JSON 解出）。
- `ExternalPluginLoader`：`dlopen` → `dlsym("chassis_plugin_entry")` → 版本协商 → 构造适配器。
- CMake/SwiftPM 均可产出该 dylib；官方提供 `PluginSDK`（Swift 包装层），
  第三方写 Swift 时只需实现 `FeaturePlugin`，由 SDK 负责导出 C 符号与桥接。

### 4.4 Library Validation 与签名

| 场景 | 策略 |
|---|---|
| 同 Team 签名（自研/合作伙伴） | 保持 Library Validation 开启，无需降级 |
| 异 Team 第三方 | 需要 `com.apple.security.cs.disable-library-validation`；**默认关闭**，仅在用户开启「允许第三方插件」并二次确认后加载 |

即使开启，也必须维持：Team ID 白名单（可配置）、签名有效性、`apiVersion` 匹配。
签名不合格的插件**不提供**「仍然加载」选项。

---

## 5. 权限模型：两层门控

```
第 1 层 TCC（系统 → 基座进程）      辅助功能 / 输入监控 / 屏幕录制 + 通知
        ↓ 基座已获授权，插件共享，不重复弹框
第 2 层 基座按插件授权（本设计新增）  required/optional ∩ 用户对该插件的勾选
        ↓ 不满足 → 插件不 activate、不订阅、不投递事件
插件看到的 permissions.status(of:)   = TCC 已授权 && 该插件被授予
```

### 5.1 数据结构

```swift
// 基座侧，不进 PluginAPI 的公开签名
struct PluginConsent: Codable {
    var granted: Set<Capability>      // 用户对「这个插件」勾选的能力
    var grantedAt: [Capability: Date]
    var manifestFingerprint: String   // 清单变了就要求重新确认
}
// HostStore: ["consent.<pluginID>": PluginConsent]
```

`manifestFingerprint` 是关键：插件升级后如果**新增**了能力声明，旧同意不自动继承，
必须重新弹确认（只做加法校验：能减少，增加就要重确认）。

### 5.2 启用流程（用户可见）

```
开关 ON
 ├─ 插件声明了 required/optional 能力
 │    → 弹出确认面板：
 │        「<插件名> 请求以下能力」
 │         ✓ 辅助功能   —— 用于 <一句用途>
 │         ✓ 屏幕录制   —— 可选，拒绝后功能降级
 │        ⚠︎ 该插件与基座同进程运行，可获得与基座相同的系统权限；
 │          基座只能限制它通过插件 API 使用事件与快捷键。
 │        [取消] [允许并启用]
 ├─ 用户全选/部分选择 → 写入 consent → 状态置 active 并 activate
 └─ 拒绝任一 required → 状态 missingCapabilities，不加载代码
```

- 能力确认是**每次启用都会显示**（不是一次性弹窗），并在插件详情页常驻「此插件已获授权的能力」区块，可随时收窄。
- 收窄（撤销某项 required）→ 立即 `deactivate` + 取消订阅 + 注销快捷键，与 TCC 被收回的行为一致。
- optional 被拒 → 插件照常激活，`permissions.status` 返回 false，由插件降级。

### 5.3 与 TCC 的关系

- TCC 仍然只有基座一条记录，用户**不需要**为插件再次授权（满足需求 2）。
- 插件侧 `PermissionService.request` 语义调整为：**只能请求当前插件已获同意、但 TCC 尚未授予**的能力。
  未获同意的能力，`request` 直接返回失败并记日志（不允许插件绕过用户对它的授权）。
- 权限页的「消费者计数」加上插件维度：`辅助功能 · 3 个已启用插件需要（其中 1 个未授权）`。

---

## 6. 生命周期与失败处理

| 场景 | 行为 |
|---|---|
| 加载失败（符号缺失 / 版本不符） | 状态 `failed("…")`，不进激活流程，**不影响其他插件** |
| `activate` 返回非 0 | 同上，基座按 owner 强制清理订阅与快捷键 |
| 插件崩溃 / `fatalError` | **基座一起退出**（同进程无法隔离）。下次启动标记该插件为 `failed` 并要求用户确认后再加载 |
| 连续两次启动即崩溃 | 自动进入 `disabled` 并提示「该插件可能导致基座不稳定」 |
| 卸载时插件仍启用 | 先 `deactivate` + 强制清理，再移出注册表 |

崩溃标记需要「启动中」哨兵：加载前写 `loading.<id> = true`，activate 成功后清除；
若下次启动仍为 true，说明上次死在加载/激活阶段。

---

## 7. UI 变化（`HostApp`）

1. **插件页**
   - 顶部新增「安装插件…」按钮（`NSOpenPanel`，允许 `.chassisplugin` 目录或 zip）
   - 行内新增来源标签：`内置` / `第三方`；未启用时状态为「未启用」
   - 行尾齿轮按钮 → 进入插件设置页（仅 `active` 可点；否则置灰并给原因）
2. **插件详情页**（现有 `PluginDetailView` 扩展）
   - 清单信息：名称 / 版本 / 发行方 / 安装时间 / 签名 Team / 文件位置
   - 「已授权能力」区块：逐项勾选，撤销 required 立即停用
   - 第三方插件额外显示「重新验证签名」与「在 Finder 中显示」
3. **安装确认页**（新窗口）：名称、图标（SF Symbol 或包内图）、权限清单、同进程警告、取消/安装
4. **权限页**：消费者计数按插件维度细化，并标注「插件授权」与「系统授权」的区别

---

## 8. 工程改动清单

| 位置 | 改动 |
|---|---|
| `Packages/PluginABI`（新） | C 头文件 + `chassis_host_services` vtable；无 Swift 依赖 |
| `Packages/PluginAPI` | 保持 Swift 供内置插件；新增 `PluginConsent` 相关类型（仅基座用） |
| `Packages/PluginKit` | 新增 `ExternalPluginLoader`、`DynamicPluginAdapter`、`PluginConsentStore`、`PluginInstaller`（校验/复制/注册） |
| `HostApp` | 安装按钮与确认页、详情页授权区块、来源标签、齿轮跳转 |
| `Plugins/` 模板 | `Scripts/new-plugin.sh` 生成插件包骨架 + `PluginSDK` 包装层 |
| `project.yml` | Host 增加 `disable-library-validation`（受设置开关影响，默认关闭）；打包第三方时启用 |
| CI | `codesign --verify`、`apiVersion` 检查、清单与 API 一致性检查 |

内置插件（当前 6 个）**保持静态链接不变**，用于零风险验证；外部插件走新路径。
两条路径在 `PluginRegistry` 内统一为同一抽象，UI 不区分实现。

---

## 9. 验收标准

| 编号 | 判据 |
|---|---|
| E1 | 导入一个签名正确的 `.chassisplugin`：列表出现，状态「未启用」，未加载代码（`dlopen` 计数 0） |
| E2 | 启用时弹出逐能力确认；拒绝 required → 状态缺权限，插件代码从未被加载 |
| E3 | 允许后插件激活，能收到点击/键盘事件（其已获授权的能力范围内） |
| E4 | 撤销某能力 → 插件立即停用，订阅计数归零，tap 按需销毁 |
| E5 | 插件升级新增 required 能力 → 再次启用时强制重新确认，旧同意不继承 |
| E6 | 伪造/未签名/Team 不在白名单 → 安装阶段拒绝，并说明原因，不提供绕过选项 |
| E7 | `apiVersion` 不匹配 → 拒绝加载，插件保持「未启用（不兼容）」 |
| E8 | 点插件设置进入插件自己的页面；非 active 时该入口不可用并给出原因 |
| E9 | 卸载第三方插件 → 先停用、清理订阅与快捷键，再移出注册表 |
| E10 | 插件在 activate 中崩溃 → 下次启动标记为 failed 并要求确认，不自动重试 |

---

## 10. 分阶段实施建议

| 阶段 | 内容 | 风险 | 可独立验收 |
|---|---|---|---|
| **P0** | 逐插件授权（consent store + 启用确认 + 详情页勾选 + 权限门控） | 低，纯基座内改动，内置插件也能受益 | E2/E4/E5（用内置插件验证） |
| **P1** | 包格式 + 安装/卸载 UI + 签名校验 + 注册表（先不加载） | 中 | E1/E6/E9 |
| **P2** | `PluginABI` + 动态加载 + `PluginSDK` + 一个示例外部插件 | 高，涉及 ABI 与 Library Validation | E3/E7/E8 |
| **P3** | 崩溃哨兵与自动降级、第三方开关、审计日志 | 中 | E10 |

建议先做 **P0**：它是「基座按插件授权」这个核心诉求的载体，且完全不依赖动态加载，
可以在现有 6 个内置插件上立刻验证；P1/P2 再决定是否真的开放异 Team 插件。

---

## 11. 未解决 / 需要产品决策

1. **异 Team 插件的 Library Validation 降级**是否接受？不接受 → 插件必须由我们签名（等于只对合作伙伴开放）。
2. 插件是否需要**公证**（notarization）？只做签名校验会被篡改替换（本地校验可缓解）。
3. 同进程崩溃带走基座，是否接受？不接受 → 回到 XPC 方案，代价是每插件独立 TCC 授权（与需求 2 冲突）。
4. 插件包的**分发渠道**（官网 zip / 应用内下载）与更新机制（本设计不含自动更新）。
5. 是否允许插件携带自己的本地化资源覆盖基座渲染的标题（当前设计：不允许，清单为准）。

---

## 12. 实现记录（落地后补充）

| 阶段 | 实际落点 | 验证方式 |
|---|---|---|
| P0 逐插件授权 | `PluginConsentStore`、`PluginRegistry.grantConsent/revokeConsent/missingConsent`、`PluginConsentSheet`、详情页授权区块 | 编译 + 启动冒烟；撤销 required 会立即停用 |
| P1 包格式与安装 | `PluginPackageManifest`、`PluginInstaller`（结构/签名/版本校验、复制、注册表、卸载进废纸篓）、`InstallPluginSheet`、插件页「安装插件…」 | `swift run PluginCheck <pkg>` 全链路 |
| P2 动态加载 | `Packages/PluginABI`（C）、`ExternalPluginLoader`、`ExternalPluginServices`（C 函数指针表）、`ExternalPluginAdapter`、`HelloPlugin` 示例 | 同上，状态由 disabled→active→disabled，tap 计数归零 |
| P3 崩溃哨兵 | **未实现**（本轮范围外） | — |

实现中根据实际情况做的调整：

1. **清单位置改为 `Contents/Resources/manifest.json`**。放在 `Contents/` 根会被 codesign 当作嵌套代码，导致整包无法签名。
2. **只对整包签名，校验也针对整包**：`SecStaticCodeCreateWithPath` 对包内文件会自动解析到外层 bundle，按文件校验反而永远拿不到签名。
3. **`com.apple.security.cs.disable-library-validation` 已加入 entitlements**：这是加载异 Team 插件的前提。安全边界改由「Team 白名单 + 允许第三方插件开关」在运行期把守（默认关闭）。
4. **`NotifierImpl` 对无 bundle 环境降级**：开发期 CLI（`PluginCheck`）没有 bundleProxy，`UNUserNotificationCenter.current()` 会抛 NSException；现在按需创建并允许为 nil。
5. **示例插件与校验工具**：`Chassis-Plugins/Examples/build-hello.sh` 产出 `dist/HelloPlugin.chassisplugin`；
   `swift run PluginCheck <pkg>` 会依次执行 清单校验 → 安装 → 注册 → 授权 → 启用 → 设置页检查 → 停用 → 卸载，并可重复运行。
