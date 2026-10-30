# Chassis

插件化 macOS 工具基座。基座自身**不含任何业务功能**，只提供应用壳层、设置界面与插件运行机制；所有功能以静态模块形式接入。

- 设计依据：`docs/Host-Architecture-Design.md`（v2.2）
- 插件规范：`Chassis-Plugins/docs/Plugin-Development-Guide.md`（v1.1，在插件仓库内）
- 当前交付：**M0 纯基座 + M1 探针插件**（插件源码在独立仓库 `Chassis-Plugins/`）

## 仓库组成

两个独立 git 仓库，检查在同一目录下（插件目录已被基座仓库忽略）：

```
Chassis/                  ← 基座仓库（本仓库）
└── Chassis-Plugins/      ← 插件仓库（独立 git，需单独 clone）
```

首次拉取基座仓库后，需要把插件仓库放到 `Chassis-Plugins/`：

```bash
git clone <插件仓库地址> Chassis-Plugins
```

`Package.swift` 用路径把 `Chassis-Plugins/Packages/Harness` 编进同一个二进制——静态链接模型下「注册表即链接清单」；目录缺失时构建会失败，`bootstrap.sh` 会提示。

## 构建

```bash
./Scripts/bootstrap.sh     # 安装 xcodegen（缺失时）、生成图标、生成 Chassis.xcodeproj
./Scripts/build.sh         # Debug 构建（与 Dock2Min 同一开发证书），输出 .app 路径
./Scripts/build.sh Release # Release 构建（同一签名身份，探针插件不注册）
./Scripts/run.sh           # 构建后启动
./Scripts/install.sh       # 构建并替换 /Applications/Chassis.app 后启动（默认 Release）
./Scripts/install.sh Debug # 调试构建（含 Harness 源码，但不注册任何插件）
./Scripts/check-guidelines.sh   # 规范兜底检查
swift build                # 单独校验 SwiftPM 各库 target
```

工程文件由 `project.yml` 生成（`*.xcodeproj` 不入库）：

```bash
xcodegen generate
xcodebuild -project Chassis.xcodeproj -scheme Chassis -configuration Debug \
  -derivedDataPath .build/xcode CODE_SIGN_IDENTITY="-" build
```

## 工程结构

| 路径 | 内容 |
|---|---|
| `Packages/PluginAPI` | **独立包**：纯接口层 + C 原子垫片 `Sources/AtomicsShim`（唯一实现是 `AtomicFlag`） |
| `Packages/PluginSupport` | **独立包**：可选共享工具（纯函数）+ `HotKeyRecorder` 控件 |
| `Packages/PluginKit` | 根包的 target：InputBus / PermissionGate / Registry / HotKey / Notifier / Store / TaskRunner |
| `Chassis-Plugins/` | **另一个仓库**：插件源码、插件规范文档 |
| `HostApp` | 应用壳层：菜单栏、设置四页、诊断导出 |
| `Scripts` | 工程生成、构建、运行、规范检查、图标生成 |

两个接口包可独立构建，插件仓库通过路径依赖复用同一份声明：

```bash
swift build                                   # 根包：PluginKit + Harness
swift build --package-path Packages/PluginAPI  # 接口层
swift build --package-path Chassis-Plugins     # 插件仓库（独立构建）
```

## 已接入插件（`Chassis-Plugins`）

| 插件 | 功能 | 能力声明 |
|---|---|---|
| `DockActions` | 点击前台应用的 Dock 图标最小化；⌥⌘1~9 / ⌥⌘↓ 操作 Dock 应用；黑白名单 | `.accessibility` |
| `SlowQuit` | 长按 ⌘Q 达设定时长才退出前台应用，按住期间显示进度环 | `.inputMonitoring` |
| `WindowSwitcher` | ⌥Tab 在所有窗口间切换；图标模式默认，实时缩略图可选 | `.inputMonitoring` + `.accessibility`，可选 `.screenCapture` |
| `DockHoverPreview` | 悬停 Dock 图标弹出该应用窗口预览，点击切换；图标默认，缩略图可选 | `.accessibility`，可选 `.screenCapture` |
| `UsageStatistics` | 按日统计各应用前台时长（本地保留 30 天） | 无（零权限） |
| `Harness` | 基座探针（仅 Debug 构建注册） | `.accessibility` + `.inputMonitoring`，可选 `.screenCapture` |

**基座不内置任何插件**：全新安装后列表为空，插件全部以 `.chassisplugin` 包导入（或从插件市场安装）。
安装 ≠ 启用，启用前还要过逐插件授权。上表插件源码在 `Chassis-Plugins` 仓库，用下面的脚本打成包：

```bash
./Chassis-Plugins/Scripts/package-plugins.sh              # 全部
./Chassis-Plugins/Scripts/package-plugins.sh SlowQuit     # 单个
# 产物：Chassis-Plugins/dist/*.chassisplugin，导入「插件 → 安装插件…」
```

插件与基座共享 `PluginAPI` 类型：插件编译成动态库，用 `-undefined dynamic_lookup` 在加载时
从基座可执行文件解析符号（基座以 `-export_dynamic` 导出），因此不需要 C ABI 胶水，
也不会出现两份 PluginAPI。

插件全部默认关闭：未启用时不申请权限、不订阅事件。

## 外部插件（安装 / 授权 / 加载）

插件可以打包成 `.chassisplugin` 由用户导入，**与基座同进程运行**，因此不需要再次通过系统授权；基座对每个插件单独收口。

```
插件页「安装插件…」→ 校验清单与签名 → 确认页（能力清单 + 同进程警告）
   → 复制到 ~/Library/Application Support/com.gaelthas.chassis/Plugins/
   → 列表出现，默认未启用（此时从未 dlopen）
   → 启用前弹出逐能力授权 → 允许后加载动态库并 activate
   → 插件详情页的齿轮/作者区即插件自己的设置页
```

- 默认只信任与基座同 Team 签名的插件；`通用 → 允许安装第三方插件` 打开后才接受异 Team / ad-hoc（对应 `disable-library-validation`，安全基线下降）。
- 逐插件授权独立于 TCC：插件看到的 `permissions.status` = 系统已授权 **且** 用户给过该插件授权；撤销必需能力会立即停用插件。
- 插件升级若新增能力声明，旧授权不继承，必须重新确认。

相关实现：`Packages/PluginABI`（纯 C ABI）、`PluginConsentStore` / `PluginInstaller` / `ExternalPluginLoader`（PluginKit）、`PluginConsentSheet` / `InstallPluginSheet`（HostApp）。

```bash
# 构建示例外部插件（ad-hoc 签名，仅本地测试）
./Chassis-Plugins/Examples/build-hello.sh

# 全链路校验：清单 → 安装 → 注册 → 授权 → 启用 → 设置页 → 停用 → 卸载
swift run PluginCheck Chassis-Plugins/Examples/dist/HelloPlugin.chassisplugin
```

## 插件市场与自动更新

市场只提供元数据（索引 + 包地址），安装仍走外部插件的完整校验与逐插件授权。

```
设置 → 插件市场
  ├─ 索引经 Ed25519 签名校验（公钥来自 Info.plist / UserDefaults）
  ├─ 包下载后校验 sha256，再交给 PluginInstaller 校验代码签名与版本
  ├─ 自动检查：启动后 5s 首次，之后每 6 小时（默认开启）
  └─ 自动安装：默认关闭；更新若改变能力声明，插件会暂停并要求重新授权
```

**多市场**：官方市场地址内置在 Info.plist（默认指向 `Chassis-Plugins` 仓库的 `Market/index.json`），
用户可在「插件市场 → 添加市场…」追加任意第三方市场。每个市场自带签名公钥，互不共享信任；
同名插件按来源顺序取第一个（官方优先）。

**发布**（在 `Chassis-Plugins` 仓库）：

```bash
./Scripts/publish.sh --bump patch SlowQuit   # 只升 SlowQuit 的版本并发布
./Scripts/publish.sh                         # 全部插件按当前版本重新打包
# 产物：Market/packages/<id>-<version>.zip + 签名后的 Market/index.json
git add Manifests Market && git commit -m "release: SlowQuit" && git push
```

索引里每个插件只出现一次（最新版）。只发布一个插件时，其余条目原样复用旧包文件，
所以不需要给每个版本单独建 GitHub Release——整个 `Market/` 目录就是一个可增量更新的市场。

本地联调（DEBUG 构建允许本地未签名索引）：

```bash
# 1) 构建示例插件并生成/签名索引
./Chassis-Plugins/Examples/build-hello.sh
bash Chassis-Plugins/Market/build-market.sh

# 2) 让基座指向本地索引
defaults write com.gaelthas.chassis host.marketplaceURL \
  "file://$PWD/Chassis-Plugins/Market/index.json"

# 3) 全链路校验：索引 → 下载 → 校验 → 安装 → 启用 → 升级检测 → 卸载
swift run MarketCheck "file://$PWD/Chassis-Plugins/Market/index.json"
```

签名密钥与发布流程见 `docs/Marketplace-Design.md`。

## 权限与授权

启动路径**不申请任何权限**，也不创建任何 Event Tap。权限只在用户点击「授权」时请求：

| 能力 | 探测 | 申请 |
|---|---|---|
| 辅助功能 | `AXIsProcessTrusted()` | `AXIsProcessTrustedWithOptions(prompt:)` |
| 输入监控 | `IOHIDCheckAccess(.listenEvent)` | `IOHIDRequestAccess(.listenEvent)` |
| 屏幕录制 | `CGPreflightScreenCaptureAccess()` | `CGRequestScreenCaptureAccess()` |
| 通知（非 Capability） | `UNUserNotificationCenter.notificationSettings` | `requestAuthorization` |

同一能力每次启动最多弹一次系统框，之后按钮等价于「打开系统设置」。用户从系统设置返回应用时（窗口重新获得焦点或应用重新激活）自动重探测，权限页另提供「重新检测」。

### 权限排障（「系统里已授权但界面显示未授权」）

macOS 的 TCC 按**代码签名要求**识别应用，而不是按路径或名字：

- ad-hoc 签名的 designated requirement 是 **cdhash**。每次重新构建 cdhash 都变，系统会把新构建当成另一个应用，旧授权不再生效——这正是早期版本的症状。
- 同一 bundle id 的多份拷贝（`.build/xcode/.../Chassis.app` 与 `/Applications/Chassis.app`）在 ad-hoc 签名下同样是不同的应用，你授权的可能是另一份。

因此工程签名设置与父项目 Dock2Min 保持一致，写在 `project.yml` 里（脚本构建与 Xcode GUI 构建都生效）：

```yaml
CODE_SIGN_STYLE: Automatic
DEVELOPMENT_TEAM: 4U5PHGQCK2
CODE_SIGN_IDENTITY: "-"
"CODE_SIGN_IDENTITY[sdk=macosx*]": Apple Development
```

其 designated requirement 绑定证书而非 cdhash，重新构建后授权依旧有效：

```
designated => identifier "com.gaelthas.chassis" and anchor apple generic and certificate leaf[subject.CN] = "Apple Development: ..."
```

处理已授权却仍显示未授权的步骤：

1. `./Scripts/install.sh`（构建 → 替换 `/Applications/Chassis.app` → 启动），避免同时存在新旧两份。
2. 系统设置里删除旧的「Chassis」条目（选中后按 `-`），再从新安装的应用里点「授权」重新添加。
3. 输入监控在部分 macOS 版本上需要**重启应用**才生效。
4. 仍不生效时点权限页「重新检测」，或重启应用（系统对已运行进程可能缓存 TCC 结果）。

没有开发证书时脚本会退回 ad-hoc，此时每次重新构建都需要重新授权一次。

## 人工验收（M0 / M1）

M0：
1. 首次启动：菜单栏出现模板图标（浅色/深色均可读），设置窗口显示应用名、版本 1.0.0 (1)、版权。
2. 全新环境启动：无任何系统权限弹框；诊断导出中 `keyboardTap=false mouseTap=false pointerMonitor=false`。
3. 权限页：三项能力 + 通知分组展示；点「授权」才会弹系统框；无插件使用时显示「当前无插件使用」。
4. 通用页：关闭菜单栏图标会先说明后果；隐藏后再次启动应用可重新打开设置窗口。
5. 开机自启：注册失败时开关回滚为真实状态（`SMAppService.mainApp.status`）。
6. 关于页：插件统计、导出诊断信息包含版本 / 插件清单 / 权限状态 / 最近日志。

M1（打开探针插件后）：
1. 未授予「辅助功能 + 输入监控」时，探针插件状态为「缺少权限」，不激活、不订阅、不弹框。
2. 授权后返回应用，插件自动变为已启用（无需重启）。
3. 点击 / 双击 / 右键在事件输出中区分正确，`frontmost=` 为点击前的前台应用。
4. 打开「同步吞掉按键」，其他应用收不到订阅范围内的按键。
5. 连发 3 条通知只出现 1 条；设置窗口在前台时不弹横幅；关闭插件后点击历史通知不激活插件。
6. 打开「停用时故意不取消订阅」后关闭插件，诊断导出中的 tap 数应归零（强制清理生效）。
7. 修改快捷键：与其他插件/系统冲突时提示来源且旧键继续生效。
8. 截图组在缺「屏幕录制」时降级为窗口列表文本。

## 已知边界

- 系统没有公开 API 稳定区分「未授权」与「策略受限」，`isRestricted` 仅在能确认时返回 true，权限页仍保留第三态。
- tap 线程遵守「无分配、无锁、不碰 AppKit」，但每次回调对不可变订阅快照有一次 ARC 读；严格的零 ARC 路径需要 C 侧路由表，M0 未引入。
- 截图为占位素材，替换 `HostApp/Resources/Assets.xcassets` 下 PNG 即可。
