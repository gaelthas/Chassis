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
./Scripts/install.sh       # 构建并替换 /Applications/Chassis.app 后启动（推荐，TCC 授权稳定）
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
| `Harness` | 基座探针（仅 Debug 构建注册） | `.accessibility` + `.inputMonitoring`，可选 `.screenCapture` |

插件全部默认关闭：未启用时不申请权限、不订阅事件。

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
