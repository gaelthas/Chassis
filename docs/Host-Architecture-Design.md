# macOS 插件化工具 · 基座技术方案设计

> 文档版本：v2.2（接口定稿修订：manifest 拆分、ClickContext 标量化、中断订阅入口、权限按订阅类型映射、`performBackground` 改名，见 ADR-21~26）
> 状态：设计定稿
> 设计形态：**从零构建的独立项目**，不继承任何既有实现
> 交付目标：先交付**纯基座**（自身不包含任何业务功能），功能全部以插件形式后续接入
> **配套文档**：`Chassis-Plugins/docs/Plugin-Development-Guide.md`（插件开发规范，位于插件仓库）—— 本文档定义"为什么这样设计"，配套文档定义"插件怎么写"

---

## 1. 范围与定义

### 1.1 什么是「纯基座」

本期交付的产物是一个**可独立安装使用的完整应用壳**，具备应用身份与基础设置能力，但不包含任何业务功能：

**基座必须自带的（应用壳层）**：

- 应用名称与图标（来自 Bundle，不硬编码）
- 菜单栏图标 + 设置窗口
- **权限页**：三项 Capability 与通知的状态显示、授权按钮、跳转系统设置
- **通用页**：开机自启、菜单栏显示、窗口行为
- **关于页**：软件名称、版本号、构建号、版权、诊断信息导出
- 插件列表（空态引导）

**基座不得自带的（业务行为）**：

| 维度 | 空载基座的实际状态 |
|---|---|
| Event Tap | **0 个**。无插件订阅即不创建任何全局输入监听 |
| TCC 权限 | **启动过程 0 次请求**。权限页的授权按钮由用户点击触发，是唯一的请求入口 |
| Accessibility 调用 | **0 次**。不做任何跨进程 UI 查询 |
| 系统影响 | 除自身内存占用外，对系统输入、窗口、焦点零影响 |

**关于"0 次权限请求"的准确含义**：指**启动路径**上不存在任何自动请求。基座提供权限申请 UI，但只有用户主动点击时才可能触发系统弹窗。两者的区别是产品体验的核心——用户第一次打开设置窗口，看到的是三个"未授权"的静态状态和一排按钮，而不是接连弹出的对话框。

这是一条硬性验收线：**"纯基座"是否达标，取决于它关闭了所有插件后是否真的什么都没做。**

### 1.2 术语

| 术语 | 含义 |
|---|---|
| **基座（Host）** | 常驻进程与应用壳，持有系统权限，提供全局资源、生命周期、权限入口、UI 容器 |
| **插件（Plugin）** | 编译期链接进基座的静态模块，承载一个业务功能，全部可开关 |
| **能力（Capability）** | 一种系统授权（辅助功能 / 输入监控 / 屏幕录制），插件声明依赖，基座负责探测与申请收敛 |
| **应用壳层（App Shell）** | 名称、图标、版本、菜单栏、设置窗口、关于页等应用身份与基础设置 |
| **订阅者（Subscriber）** | 插件在输入总线上登记的事件兴趣，是插件感知输入的**唯一**途径 |
| **纯基座（Bare Host）** | 未启用任何插件的基座状态 |

### 1.3 非目标（Non-goals）

- ❌ 不做第三方插件生态、插件市场、插件签名审核
- ❌ 不做运行时插件加载（`dlopen` / 动态 framework）、热重载、独立升级
- ❌ 不做进程外插件（XPC）
- ❌ 不在本期实现任何业务功能（包括任何"看起来像基座自带"的默认能力）
- ❌ 不兼容任何历史配置格式（**无数据迁移，全新配置基线**）
- ❌ 不做 App Store 分发

---

## 2. 设计原则

贯穿全文决策的六条原则，冲突时优先级自上而下：

**P1 · 基座无功能**
基座只提供机制，不提供策略。任何"用户能感觉到它在工作"的行为都必须属于某个插件，且必须可关闭。

**P2 · 权限最小化与延迟获取**
基座启动不申请任何权限。权限只在用户显式启用某个需要它的插件时申请，且申请必须由用户手势触发。权限被收回时，相关插件自动降级而非崩溃。

**P3 · 输入链路上不做有状态的事**
全局输入回调是系统级共享资源，其执行时间直接影响所有应用的输入响应。回调常驻路径只允许无状态、无分配、无锁的标量运算。

**P4 · 能在编译期强制的才叫约束，其余如实标为约定**
模块可见性、插件互不可见、`@Sendable` 闭包捕获限制——这些可以用类型系统和 SwiftPM 依赖声明强制。除此之外不假装有保证。**绝不把"文档规定"包装成"架构保证"**，否则后续维护者会基于错误前提做判断（§9.2 如实列出每一条的真实强度）。

**P5 · 不为尚未出现的需求付出复杂度**
静态链接够用就不做动态加载；单进程够用就不做多进程。复杂度只在需求被证实后才引入。

**P6 · 基座不提供系统 API 封装**
基座只提供三样东西：全局资源的唯一入口、全局副作用的收敛点、事件时刻的事实快照。任何"替插件调一次系统 API 并把结果加工后返回"的方法都不进基座——无论它出现多少次、看起来多方便（§4.4）。

---

## 3. 平台约束

以下五条是 macOS 的既定事实，架构必须服从，不可通过设计规避。

### 3.1 权限不可转授，只能共享或门控

TCC（Transparency, Consent, and Control）的授权记录绑定**进程身份**（可执行路径 + 代码签名 designated requirement）。系统**不存在**任何 API 允许进程 A 把自己的辅助功能授权委托给进程 B。

由此得到三条结论：

1. 插件要"共用一次授权"，**必须与基座同进程**。
2. 所谓"基座管理插件权限"，真实语义只能是**能力门控**：集中探测授权状态、在缺失时拒绝下发能力、引导用户授权。基座无法替插件"获得"权限。
3. 插件一旦进程外化，用户会在系统设置中看到多条独立条目并需逐条授权，"安装一次、授权一次"的产品假设立刻失效。

### 3.2 输入事件是全局稀缺资源

`CGEvent.tapCreate` 创建的 tap 位于系统全局事件链。**拦截型**（`.defaultTap`）回调同步阻塞事件派发——回调不返回，用户的键盘就没有响应。**旁听型**（`.listenOnly`）虽不阻塞，但每个 tap 仍然是一次全局链上的额外调度。

由此得到两条硬规则：

1. 全应用最多持有 **1 个键盘 tap + 1 个鼠标 tap**，由基座独占创建，插件只能订阅。
2. 拦截型 tap 回调预算以**微秒**计：禁止内存分配、加锁、IPC、跨队列同步等待。

推论：**tap 的数量必须与插件数量解耦**。若每个插件自行创建监听器，N 个插件就是 N 层累积延迟，且随功能增长线性恶化——这是必须由基座统一持有事件源的根本原因。

### 3.3 进程内插件无故障隔离

同进程插件的崩溃会带走整个基座。Swift 的 `fatalError` / `precondition` 无法被捕获，`try/catch` 只覆盖 `throws`。

结论：**安全性由编译期约束与窄接口设计保证，而非运行时沙箱**。插件 API 必须刻意做窄——窄接口降低插件作者误入危险路径的概率。

### 3.4 分发与签名

依赖辅助功能权限的应用无法通过 App Store 审核。本项目走 Developer ID 直分发，因此无需为过审妥协。

静态链接带来一个额外收益：**Hardened Runtime 的 Library Validation 对此架构完全不适用**——校验对象是运行时 `dlopen` 的库，而静态链接进主二进制的插件代码不属于"加载的库"。因此无需为支持插件而关闭 `disable-library-validation`，安全基线不受损。这是选择静态模块而非动态加载的重要理由之一（另一理由见 P5）。

### 3.5 由约束导出的三个结构性结论

| 结论 | 依据 |
|---|---|
| 插件 = 同进程静态模块 | §3.1（权限共享）+ §3.4（library validation 不适用） |
| 输入源 = 基座独占的单一总线 | §3.2（tap 数量与插件数解耦） |
| 插件 API = 窄的**机制**接口 + 宽的**系统 API** 访问 | §3.3（无隔离，只能在机制层面收窄，不能在 API 层面禁绝） |

---

## 4. 架构

### 4.1 分层

```
┌──────────────────────────────────────────────────────────────┐
│                         基座进程                              │
│                                                              │
│   ┌─────────────┐ ┌──────────┐ ┌───────────┐ ┌────────────┐  │
│   │ Permission  │ │ InputBus │ │  HotKey   │ │PluginStore │  │
│   │    Gate     │ │ 单一事件源│ │ Arbitrator│ │  独立配置   │  │
│   └──────┬──────┘ └────┬─────┘ └─────┬─────┘ └─────┬──────┘  │
│          │             │             │             │         │
│   ┌──────┴─────────────┴─────────────┴─────────────┴──────┐  │
│   │            PluginRegistry  ·  生命周期与状态机         │  │
│   └──────────────────────────┬────────────────────────────┘  │
│                              │ PluginContext                 │
│   ┌──────────────────────────┴────────────────────────────┐  │
│   │        SettingsContainer  ·  插件列表 + 设置页容器      │  │
│   └───────────────────────────────────────────────────────┘  │
└──────────────────────────────┬───────────────────────────────┘
                               │ 唯一依赖：PluginAPI
      ┌──────────┬─────────────┼─────────────┬──────────┐
      ▼          ▼             ▼             ▼          ▼
   Plugin A   Plugin B      Plugin C      Plugin D   Plugin E
   （全部可开关，基座内不含任何业务功能）
```

### 4.2 模块与依赖方向

```
PluginAPI  ←──  PluginKit  ←──  HostApp（可执行目标）
    ↑
    ├──────────  PluginSupport（可选共享工具，纯函数）
    ↑
    └──────────  Plugins/*（每个插件独立 module）
```

**单向依赖，禁止反向**，由 SwiftPM 的 target 依赖声明强制：

| 模块 | 内容 | 谁可以 import |
|---|---|---|
| `PluginAPI` | 仅 `protocol` / `struct` / `enum`，零实现。**唯一例外：`AtomicFlag`**（见 §6.3，tap 线程不允许动态派发） | 基座 + 全部插件 |
| `PluginKit` | `InputBus`、`PermissionGate`、`PluginRegistry`、`PluginStore`、`HotKeyArbitrator`、`TaskRunner` 的实现 | 仅 `HostApp` |
| `PluginSupport` | 可选的共享工具：AX 读写辅助、窗口枚举、坐标换算等**纯函数**。无状态、无全局资源、不做权限判断 | 插件（可选） |
| `HostApp` | 应用入口、菜单栏、设置窗口、插件注册表构建 | — |
| `Plugins/*` | 单个业务功能 | `PluginAPI`（必需）+ `PluginSupport`（可选） |

**这条约束是架构的主要安全保证**：插件在编译期拿不到 `PluginKit` 的类型，也就无法私建 Event Tap、绕过权限申请收敛、或读写其他插件的配置。

`PluginSupport` 的存在是为了解决 §4.4 中"API 下放导致重复实现"的代价——多个插件都需要"枚举某应用的窗口"这类逻辑时，把它放进 `PluginSupport` 共享，而**不是**塞回基座。判定线：**有状态或持有全局资源 → 基座；纯函数 → `PluginSupport`。**

插件仍可自行 `import ApplicationServices` / `CoreGraphics` 直接调用原始 API，这是**有意的设计**（§4.4），其风险处置见 §9.2。

### 4.3 基座服务清单

明确划定"什么在基座内、什么在插件内"。

| 基座服务 | 必需理由 | 插件如何获得 |
|---|---|---|
| `AppShell` | 应用身份（名称/图标/版本）、开机自启、关于页 | 由基座渲染，插件不可见 |
| `InputBus` | 全局唯一事件源（§3.2） | `context.inputBus` |
| `PermissionGate` | 权限**申请**必须收敛（§4.4） | `manifest` 声明 + `context.permissions` |
| `HotKeyArbitrator` | 快捷键是全局命名空间，必须防冲突 | `context.hotKeys` |
| `PluginStore` | 配置隔离 | `context.store` |
| `PluginRegistry` | 生命周期唯一管理者 | 由基座驱动 |
| `SettingsContainer` | 唯一窗口与列表 | 插件只提供 detail 视图 |
| `Notifier` | 避免各插件独立发通知造成骚扰 | `context.notifier.post(...)` |
| `TaskRunner` | 统一后台执行上下文（§4.4） | `context.performBackground { }` |
| **不允许**任何系统 API 的语义封装 | P1、§4.4 | — |

**明确不属于基座**：应用/窗口的查询与控制、图像捕获、通知模板内容、跳转系统设置、任何"帮插件做完一件事"的方法。全部由插件直接调用系统 API。

以下内容明确**归属插件**：功能开关、功能参数、功能自己的 UI、功能自己的 `activate/deactivate` 逻辑、功能自己的子开关、功能自己的 AX/CG/SCK 调用。

### 4.4 系统 API 的归属边界

> **原则：基座不提供任何系统 API 的封装。插件直接调用 `ApplicationServices`、`CoreGraphics`、`ScreenCaptureKit`、`AppKit`。**
> **基座只做三件事：独占全局资源、收敛全局副作用、捕获事件时刻的事实。**

#### 4.4.1 什么算「基座提供了系统 API」

判定标准很窄：**基座是否替插件完成了一次系统调用，并把结果加工后交给插件。**

| 形态 | 是否算封装 | 结论 |
|---|---|---|
| `context.minimize(app)` → 内部调 AX 设 `kAXMinimized` | 算 | **不提供** |
| `context.captureWindowImage(id)` → 内部调 ScreenCaptureKit | 算 | **不提供** |
| `context.openSystemSettings(for:)` → 内部调 `NSWorkspace.open` | 算 | **不提供**，插件自己打开 |
| `context.performBackground { ... }` → 只调度线程，闭包内是插件自己的调用 | 不算 | 提供（执行上下文，不是能力） |
| `context.inputBus.subscribe...` → 独占 Event Tap，投递事件值 | 不算 | 提供（资源中介，见 §4.4.2） |
| `context.notifier.post(...)` → 内部调 `UNUserNotificationCenter` | **算，但保留** | 提供的目的是统一节流（§4.4.2） |

判据一句话：**基线以下的"调度"可以给，基线以上的"结果"不给。**

#### 4.4.2 三类必要例外（资源中介，不是能力封装）

这三项必须经基座，因为它们是**全局资源或全局副作用**，不是某个插件的私有能力：

| 例外 | 为什么必须经基座 | 插件拿到的是 |
|---|---|---|
| **全局输入事件** | Event Tap 必须全局唯一（§3.2）。若每个插件自建，N 个插件 = N 层累积延迟，且无法回收 | 已解析的**事件值**（`KeyEvent` / `ClickContext`），不是 `CGEvent` 对象 |
| **权限申请** | 申请会弹系统框。多插件并发申请会堆叠对话框，用户无法归因 | `request` 入口；`status` 只是基座门控结果的只读暴露，插件可不用，自己调 `AXIsProcessTrusted()` 亦可 |
| **全局快捷键** | 同一命名空间，自建注册必然静默冲突 | `register/update/availability`；组合键内容由插件决定 |
| **系统通知** | 各插件独立发通知会互相淹没用户 | `notifier.post(...)`；文案由插件决定 |

**注意区分"资源中介"与"能力封装"**：`inputBus` 返回的是事件值，插件仍需自己判断"这个点击落在哪里、要不要做事"；`hotKeys` 只负责把按键分发给正确的插件，不实现任何按键语义。基座不参与任何业务判断。

#### 4.4.3 事件事实：唯一必须由基座捕获的数据

有一个特例必须讲清楚：**某些状态在事件发生后就永久改变了，事后再查得到的是"新世界"而非"事件时刻的世界"。**

典型：一次鼠标点击会改变前台应用。当插件收到点击事件时（已异步投递到主线程），`NSWorkspace.shared.frontmostApplication` 返回的可能已经是"被点击后"的应用，而非"被点击前"的。这个信息一旦丢失就无法恢复。

因此 `ClickContext` 携带**点击瞬间的轻量快照**：

| 字段 | 含义 | 为什么必须由基座提供 |
|---|---|---|
| `location` | 全局屏幕坐标（左上原点，与 `CGEvent.location` 同一坐标系） | 只在 tap 中才有的事件值 |
| `timestamp` | 事件时间（秒，单调时钟） | 同上 |
| `button` | 触发点击的鼠标键（左/右/中） | 只有 Event Tap 能区分；基座已完成有效点击判定 |
| `clickCount` | 连击计数（区分单击 / 双击 / 多击） | 同上；离开 tap 后无法可靠重建 |
| `frontmostPID` | 点击发生**前一瞬间**的前台进程 pid | 事后查询得到的是"新世界"，不可重建 |

**为什么是 `pid_t` 而不是 `NSRunningApplication`**：两条硬约束同时排除了携带对象。

1. `ClickContext` 必须满足 `Sendable`，而 `NSRunningApplication` 不是。硬塞进去只会让插件作者用 `@unchecked Sendable` 掩盖问题，把并发风险推到最难排查的地方。
2. 更根本的是 §7 的 tap 线程禁令：**tap 线程不得访问 AppKit、不得产生分配**。`NSWorkspace.shared.frontmostApplication` 是一次 AppKit 调用，且必然伴随对象创建与 ARC 操作——在 tap 线程上做这件事，本身就违反了本文档自己定的规则。

**正确实现方式**：主线程订阅 `NSWorkspace.didActivateApplicationNotification`，把当前前台 pid 写入基座内部的原子整数；tap 线程构造 `ClickContext` 时只读这个标量，开销与 `AtomicFlag` 同级。插件拿到 pid 后，在主线程自行 `NSRunningApplication(processIdentifier:)` 解析——**对象化这一步发生在插件侧、主线程上，符合线程契约**。

由此得到一条通用规则：**基座只捕获"事件时刻的标量事实"，对象化与语义解释永远属于插件。** 这条规则同时解释了为什么 `ClickContext` 里没有任何 `NSRunningApplication` / `AXUIElement` 类型的字段。

**但这里有一条硬边界**：任何**需要 AX 调用**才能得到的状态（如"该应用当前是否有可见窗口"）**不由基座代查**。原因有二：

1. AX 调用是跨进程同步 IPC，绝不能在 tap 线程执行；异步查回来时状态已变，查了也没有意义。
2. 查什么、何时查属于业务策略，基座无权代插件决定。

**插件应当怎么做**：需要"点击前状态"的插件，应自行订阅 `pointerMove`，在指针进入目标区域时**预取并缓存**状态，点击事件到达时直接读缓存。这个预取时机、缓存失效策略、查询精度全部由插件掌握——这才是把决策权真正交还给插件。

#### 4.4.4 全量归属对照

| 能力 | 归属 | 插件如何使用 |
|---|---|---|
| 鼠标/键盘事件监听 | **基座独占** | `context.inputBus.subscribe...` |
| 全局快捷键注册 | **基座独占** | `context.hotKeys.register(...)` |
| 系统通知发送 | **基座独占** | `context.notifier.post(...)` |
| TCC 授权申请 | **基座收敛** | `context.permissions.request(...)`（仅响应用户点击） |
| 权限状态查询 | **插件可自查** | 自行 `AXIsProcessTrusted()` 等；或读 `context.permissions.status` |
| 跳转系统设置页 | **插件直接调** | 自行 `NSWorkspace.shared.open(url)` |
| AX 属性读取 / 窗口最小化 / 激活 | **插件直接调** | 自行 `import ApplicationServices`，在 `performBackground` 内执行 |
| 窗口列表枚举 | **插件直接调** | 自行调 `CGWindowListCopyWindowInfo` |
| 图像捕获 | **插件直接调** | 自行用 ScreenCaptureKit，先确认 `.screenCapture` 已授权 |
| `NSRunningApplication` 操作 | **插件直接调** | 纯 AppKit |
| 点击瞬间的前台进程 | **基座捕获**（§4.4.3） | `ClickContext.frontmostPID`，主线程自行解析为 `NSRunningApplication` |
| 点击瞬间的窗口状态 | **插件自行预取** | 订阅 `pointerMove` 缓存（§4.4.3） |

#### 4.4.5 收益与代价

**收益**：

- **接口不膨胀**：基座无需预测插件未来的需求。`minimize`、`activate`、`hide`、`moveToSpace`、`setFullscreen`……若都封装，每加一个功能都要改基座，直接违背"新增插件不修改基座"（§6.5）。
- **插件完全自由**：不受基座抽象泄漏限制，可直接使用最新系统 API。
- **无转发损耗**：AX 已是跨进程 IPC，再套一层封装只增加认知成本与调试难度。

**代价**（必须正视并接受）：

| 代价 | 表现 | 缓解 |
|---|---|---|
| 线程模型失守 | 插件在主线程发起同步 AX 调用 → UI 冻结 | `performBackground` 提供串行后台队列，且闭包 `@Sendable` 从编译期阻止捕获 Main Actor 状态 |
| 权限门控可被绕过 | 无 `.screenCapture` 时反复调捕获 API，反复触发系统拒绝 | 插件必须在调用前自查；M1 测试插件的权限用例覆盖此项 |
| 重复实现 | 多个插件各写一遍"枚举窗口""坐标换算" | `PluginSupport`：**完全可选**的共享工具库，纯函数、无状态、不做权限判断、不属于基座。插件也可一行不用 |
| 安全防护等级下降 | 编译期无法阻止插件调用任意 API | 降级为审查约定（§9.2），接受此代价 |

#### 4.4.6 为什么权限「探测」下放、「申请」收敛

- **探测**（`AXIsProcessTrusted()` / `CGPreflightScreenCaptureAccess()` / `IOHIDCheckAccess`）幂等、无副作用、无 UI，插件自己调完全安全。基座内部也必须探测（用于门控），`context.permissions.status` 只是把同一份结果只读暴露出来，不强制使用。
- **申请**（带 `prompt` 的变体）会产生系统对话框。若两个插件几乎同时申请，对话框会堆叠，用户无法归因"这个框是哪来的"。因此申请入口唯一：**只能由基座的权限页或插件设置页中一个明确的按钮触发，且同一次启动内每种权限最多弹一次**。
- 推论：插件**不得**在 `activate` 中调用 `request`。`activate` 只读状态；缺权限就进 `missingCapabilities`，由 UI 引导。

### 4.5 插件清单的发现方式

静态链接模型下不存在可扫描的插件目录，因此插件清单一律**编译期注册**：

```swift
// HostApp/PluginCatalog.swift
@MainActor
enum PluginCatalog {
    static let all: [any FeaturePlugin.Type] = [
        // 每个插件一行；空数组即为纯基座
    ]
}
```

设计要点：

- 注册表是**唯一**的插件入口，新增插件只改这一行。
- 标注 `@MainActor` 是必需的：`FeaturePlugin` 是主 actor 隔离的协议，读取 `manifest` 必须在主 actor 上；启动流程本来就在主 actor，因此不产生额外切换。
- 注册只登记**类型**，不实例化——`manifest` 是 `static`，基座可在不创建实例的前提下渲染插件列表。
- 纯基座阶段该数组为空，UI 显示空态引导。
- 不做运行时插件发现：没有可发现的对象，引入"扫描目录"只会带来安全与签名问题，违背 P5。

---

## 5. 插件契约

### 5.1 Manifest（静态元信息）

```swift
/// 插件的静态元信息，可在不实例化插件的前提下完整获取。
public struct PluginManifest {
    public let id: String                        // 反向域名，全局唯一，用于配置隔离；一经发布不可更改
    public let version: String                   // 语义化版本，用于展示与诊断
    public let minHostVersion: String            // 构建期校验（见 §6.7）
    public let title: LocalizedStringKey         // 插件列表显示名
    public let summary: LocalizedStringKey       // 一句话说明
    public let iconSystemName: String            // SF Symbol
    public let requiredCapabilities: Set<Capability>   // 缺一不可，否则不激活
    public let optionalCapabilities: Set<Capability>   // 缺失时降级运行
    public let resourceBundle: Bundle            // 插件自己的资源（本地化字符串、图片）

    public init(id: String, version: String, minHostVersion: String,
                title: LocalizedStringKey, summary: LocalizedStringKey,
                iconSystemName: String,
                requiredCapabilities: Set<Capability> = [],
                optionalCapabilities: Set<Capability> = [],
                resourceBundle: Bundle)
}
```

**这里没有 `settingsView`，是刻意的。** 设置页必须能读插件实例上的状态（改了一半的参数、正在录制的快捷键、上一次查询的缓存），而 `manifest` 是 `static`——把闭包写在 `static` 上，闭包就永远拿不到实例。草案阶段正是这么写的，代价是每次切换插件都重建一份 model，用户未保存的编辑被静默丢弃，与规范里"状态归插件对象"的要求正面冲突。

因此设置页改为 `FeaturePlugin` 的**实例方法** `makeSettingsView()`（§5.2）。这不损失"列表不实例化"的能力：列表只需要名称、版本、权限徽章，全部来自 `static` 的 `manifest`（§4.5）。

`required` 与 `optional` 必须分开，因为降级是常态而非例外：屏幕捕获权限被拒时，一个窗口切换插件应当仍能以纯文本模式工作，而不是整体不可用。

**`resourceBundle` 解决本地化归属问题**：插件的 `.strings` 与图片在自己的 target 内（SwiftPM 为 `Bundle.module`），而 SwiftUI 的 `Text(LocalizedStringKey)` 默认查 main bundle。若不给插件一个明确的 bundle 出口，所有插件文案在接入国际化时会退化成 key。基座渲染插件信息时一律用 `Text(manifest.title, bundle: manifest.resourceBundle)`。

> **实现约束**：`PluginAPI` 中所有公开 `struct`（`PluginManifest`、`KeyFilter`、`KeyEvent`、`ClickContext`、`HotKeySpec`、`PluginNotification`）都**必须显式声明 `public init`**。Swift 的默认 memberwise initializer 是 `internal`，跨 module 无法使用——漏写会导致插件侧报"初始化器不可访问"，而错误信息指向插件代码，很容易误判为插件写错。以附录 A 的签名为准。

### 5.2 FeaturePlugin

```swift
@MainActor
public protocol FeaturePlugin: AnyObject {
    static var manifest: PluginManifest { get }

    /// 仅在 requiredCapabilities 全部满足、且用户已开启时调用。
    func activate(context: PluginContext) throws

    /// 关闭时调用，必须幂等，不得抛错。
    func deactivate()

    /// 设置页视图。仅在插件 active 时调用（§6.6），因此可以安全读取 self 上的状态。
    /// 每次切回该插件都会重新调用；返回值必须绑定到插件持有的 model，
    /// 不能依赖 View 自身的 @State（切走即丢，见规范 §6.1）。
    func makeSettingsView() -> AnyView
}
```

`@MainActor` 标注在**协议级别**，是防止跨线程数据竞争的第一道防线：插件所有代码都在主线程执行，无法意外触碰 tap 线程。

`AnyObject` 不是装饰：基座持有的是唯一实例，插件在订阅闭包中需要 `[weak self]`，`deactivate` 的幂等也建立在"同一对象多次进出"这一前提上。值语义的插件会让这三件事同时失真。

### 5.3 PluginContext

```swift
@MainActor
public protocol PluginContext: AnyObject {
    var pluginID: String { get }
    var hostVersion: String { get }
    var store: PluginStore { get }          // 协议，实现在 PluginKit（§6.5）
    var inputBus: InputBus { get }
    var hotKeys: HotKeyService { get }
    var permissions: PermissionService { get }
    var notifier: Notifier { get }
    var logger: PluginLogger { get }        // 刻意不叫 Logger，避免与 os.Logger 撞名

    /// 统一的后台执行上下文。可能因跨进程等待而变慢的调用（AX / 窗口枚举 / 截图）
    /// 都必须包裹其中。闭包为 @Sendable，编译期阻止捕获 main actor 状态。
    func performBackground<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T
}
```

**`AnyObject` 是必需的，不是风格问题**：`weak` 只能用于类类型，草案里 `[weak self, weak context]` 的示例在缺少这个约束时根本编译不过。

**context 的生命周期契约**（插件作者最常问的一个问题）：

- 同一插件实例在 enabled 期间只会拿到**同一个** context，基座按 pluginID 缓存，不在每次 `activate` 时新建。
- 插件**可以强持有** context：它由基座持有，生命周期覆盖插件的整个 enabled 期，不会先于插件失效。不需要 `[weak context]`。
- `deactivate` 之后基座不再向该 context 路由任何回调（订阅、快捷键、通知点击全部摘除）；此时调用 context 方法不崩溃但无效果。再次 `activate` 拿到的是同一个 context。
- 插件**无需**在 `deactivate` 中释放 context。

**为什么叫 `performBackground` 而不叫 `performAX`**：它承载的不只是 AX，而是"可能因跨进程等待而变慢的一切"——窗口枚举、同步截图封装、`NSRunningApplication.activate()`。早期草案叫 `performAX`，实际后果是插件作者看到名字就以为"截图不归它管"，转而自建 `DispatchQueue`，绕过了唯一的串行执行器，恰好破坏了它存在的理由。

**语义边界要说清，避免误解成"后台任务"**：

| 它是什么 | 它不是什么 |
|---|---|
| 一个**执行位置**：闭包不在主线程跑 | 不是 `Task.detached`，不提供优先级/取消/生命周期管理 |
| 全局**串行**：任意时刻只有一个闭包在跑 | 不是并发容器，不要指望 `async let` 并行两条 AX 调用 |
| 一次调用一个作用域，出错原样透传 | 不是长任务通道，耗时数秒的循环应自己分批并在 `Task` 里 `await` 每次调用 |

名字里的 "Background" 指执行位置，不指"后台任务"。长时间运行的工作仍应由插件用 `Task` 组织，只是其中每一次可能变慢的跨进程调用要经过这里。

**注意此处没有 `minimize(app:)` / `activate(app:)` / `captureWindowImage(...)`**。应用与窗口的查询、控制、捕获一律由插件直接调用系统 API（理由见 §4.4），基座只提供执行上下文与权限状态。这是与"厚封装基座"的关键分歧点，取舍已记录于 ADR-15。

```swift
// MARK: - 权限

@MainActor
public protocol PermissionService {
    /// 基座门控结果的只读暴露。插件也可自行调用 AXIsProcessTrusted() 等，二者等价。
    func status(of capability: Capability) -> Bool

    /// 被 MDM 或其他系统策略禁用。此时 request 必然无效，UI 应说明原因而不是给一个点了没反应的按钮。
    func isRestricted(_ capability: Capability) -> Bool

    var missing: Set<Capability> { get }        // 相对当前插件声明的缺失项

    /// 仅允许在用户手势中调用。
    /// 同一次启动内每种权限最多触发一次系统弹窗；重复调用转为跳转系统设置。
    func request(_ capability: Capability)
}
```

**跳转系统设置不在基座内**：插件需要引导用户去系统设置时，自行 `NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:..."))`。基座不代为封装——URL scheme 的稳定性由系统决定，与基座无关，且这属于纯 UI 行为，无全局副作用（§4.4.1）。

```swift
// MARK: - 快捷键

@MainActor
public protocol HotKeyService {
    /// 注册当前插件的快捷键。冲突时抛 HotKeyError（见 §6.4）。
    func register(_ spec: HotKeySpec, handler: @escaping @MainActor () -> Void) throws

    /// 用户改键时调用。基座保证原子性：新键注册失败则保留旧键，handler 不变。
    func update(_ spec: HotKeySpec) throws

    /// 查询该组合键当前是否可用。录制过程中实时调用，用于"已被 XX 占用"的即时提示。
    /// 调用者身份由 context 决定，参数中不需要（也不应该）再传 pluginID。
    func availability(of spec: HotKeySpec) -> HotKeyAvailability

    /// 主动注销本插件的快捷键。可省略——deactivate 时基座统一注销。
    func unregister()
}
```

### 5.4 能力清单

| Capability | 系统授权 | 缺失影响 | 谁真的需要它 |
|---|---|---|---|
| `.accessibility` | 辅助功能 | 跨进程 UI 读取、窗口控制，以及**鼠标 tap / 指针移动监听** | 用 AX API 的插件；订阅点击或指针移动的插件 |
| `.inputMonitoring` | 输入监控 | **键盘 tap** | 订阅 `subscribeToKey` 的插件 |
| `.screenCapture` | 屏幕录制 | 屏幕内容捕获 | 需要读屏或截图的插件 |

**必须按事件源分别映射，不能笼统写成"输入总线需要输入监控"。** 三条输入路径在系统层面归属不同授权：

| 订阅 | 底层实现 | 实际需要的授权 |
|---|---|---|
| `subscribeToKey` | `CGEvent.tapCreate(.defaultTap)` | `.inputMonitoring` |
| `subscribeToClick` | `CGEvent.tapCreate(.listenOnly)` | `.accessibility` |
| `subscribeToPointerMove` | `NSEvent.addGlobalMonitorForEvents` | `.accessibility` |

早期草案写的是"`.inputMonitoring` 缺失 → 输入总线的鼠标与键盘订阅失效"，这会让只订阅点击的插件声明错能力，用户跑到错误的系统设置页里反复授权却毫无效果。**门控必须精确到订阅类型**，这也是 `PluginContext` 里有 `permissions.missing` 而不只是布尔状态的原因。

一个只订阅点击、不订阅键盘的插件声明 `.inputMonitoring` 是错误的；反过来，只订阅键盘的插件声明 `.accessibility` 同样错误（除非它另有用 AX 的需求）。

**注意**：全局快捷键（`RegisterEventHotKey`）**不属于任何 Capability**，无需授权即可使用。插件不为快捷键声明 `.inputMonitoring`（§6.4）。

探测方式（全部为无提示的 preflight，`request` 才可能触发系统框）：

| Capability | 探测 | 请求 |
|---|---|---|
| `.accessibility` | `AXIsProcessTrusted()` | `AXIsProcessTrustedWithOptions(prompt: true)` |
| `.inputMonitoring` | `IOHIDCheckAccess(.listenEvent)` | `IOHIDRequestAccess(.listenEvent)` |
| `.screenCapture` | `CGPreflightScreenCaptureAccess()` | `CGRequestScreenCaptureAccess()` |

`IOHID` 的显式探测不可省略——Event Tap 创建失败时返回 `nil` 而不告知原因，若不主动探测，用户看到的只有"功能不工作"。

**tap 创建失败时的降级归属**：键盘 tap 因缺 `.inputMonitoring` 创建失败 → 订阅了键盘的插件进 `missingCapabilities`；鼠标 tap 因缺 `.accessibility` 创建失败 → 订阅了点击或指针移动的插件进 `missingCapabilities`。两类权限不可互相替代。

### 5.5 基座能力契约总表

`PluginContext` 共有 7 个成员，分成两类：**五项能力入口**（涉及全局资源与全局副作用，必须经基座）与**两项基础设施**（纯本地，无全局语义）。每项都给出线程、生命周期与失败语义的完整契约，**实现前必须先读对应小节**。

**五项能力入口**：

| # | 入口 | 能力 | 线程 | 生命周期 | 失败语义 | 详见 |
|---|---|---|---|---|---|---|
| 1 | `context.inputBus` | 全局输入事件（鼠标点击 / 指针移动 / 键盘 / tap 中断） | Main Actor | 订阅制，引用计数；`deactivate` 后基座强制清理 | tap 创建失败 → 相关插件进 `missingCapabilities`；tap 超时被禁 → 通过 `subscribeToInterruptions` 广播 | §6.3 |
| 2 | `context.permissions` | 权限状态、受限判定与申请 | Main Actor | 每次 `didBecomeActive` 重探测 | 申请失败不抛错，由状态反映；重复申请转跳系统设置 | §6.2、§4.4.6 |
| 3 | `context.hotKeys` | 全局快捷键注册与仲裁 | Main Actor | 插件 `activate` 时注册，`deactivate` 时基座统一注销 | 冲突抛 `HotKeyError.conflict`，插件须在自己的 UI 提示改键 | §6.4 |
| 4 | `context.notifier` | 系统通知（含节流/去重/前台抑制） | Main Actor | 全局一次授权；插件无需管理授权生命周期 | 未授权时静默丢弃并记日志，不抛错 | §6.8 |
| 5 | `context.performBackground` | 后台执行上下文（非能力，仅调度；承载 AX / 窗口枚举 / 同步捕获） | `async` | 每次调用独立，全局串行 | 闭包内抛出的错误原样透传 | §5.3、§7 |

**两项基础设施**：

| # | 入口 | 能力 | 线程 | 生命周期 | 失败语义 | 详见 |
|---|---|---|---|---|---|---|
| 6 | `context.store` | 插件私有配置（独立 UserDefaults suite） | Main Actor | 进程内常驻，跨 `activate` 复用 | 无失败路径；解码失败返回 `nil`，由插件走默认值 | §6.5 |
| 7 | `context.logger` | 带 pluginID 前缀的日志 | Main Actor | 进程内常驻 | 无失败路径；Release 下 `debug` 不落盘 | §6.8 |

**为什么 `store` 和 `logger` 不算"能力"**：它们不涉及全局资源唯一性，也不产生用户可见的全局副作用——一个插件写坏自己的 suite 只影响自己。因此它们不需要仲裁、不需要引用计数、不参与门控。把它们与五项能力并列会模糊"什么必须经基座"这条判据（§4.4.1）。

#### 共同契约

| 约定 | 说明 |
|---|---|
| 全部 Main Actor | 除 `performBackground` 的 `async` 外，所有调用点都在主线程，插件不需要考虑并发 |
| 不抛错或只抛特定错误 | 只有 `hotKeys.register/update` 抛 `HotKeyError`。其余入口失败时**改变状态**而非抛错——状态是可观察的，异常容易漏处理 |
| 基座负责清理 | 插件 `deactivate` 后，订阅、快捷键、通知点击回调全部由基座清理。插件**可以**主动清理（推荐），但遗漏不会造成泄漏 |
| 不可绕过的边界 | 这七项之外的系统 API 插件可直接调用；其中五项能力**不可**自建替代实现（自建 Event Tap / 自建快捷键注册会破坏全局唯一性，见 §4.4.2） |
| 权限前置自查 | 调用任何需要 Capability 的系统 API 前，插件必须自查 `context.permissions.status`。基座不会拦截这些调用（§9.2） |

#### 一个必读的例子：能力组合的正确顺序

```swift
@MainActor
final class ExamplePlugin: FeaturePlugin {
    static let manifest = PluginManifest(
        id: "com.example.plugin.demo",
        version: "1.0.0",
        minHostVersion: "1.0.0",
        title: "示例",
        summary: "演示五项能力",
        iconSystemName: "star",
        requiredCapabilities: [.accessibility],     // 点击订阅走鼠标 tap（§5.4）
        optionalCapabilities: [.screenCapture],
        resourceBundle: .module
    )

    // context 可强持有：生命周期覆盖整个 enabled 期（§5.3）
    private var context: PluginContext?
    private var clickSub: Subscription?
    private var interruptSub: Subscription?
    private var previousState: CGWindowID?
    private var settingsModel: DemoSettingsModel?   // activate 时创建一次，之后复用

    func activate(context: PluginContext) throws {
        self.context = context
        if settingsModel == nil { settingsModel = DemoSettingsModel(store: context.store) }

        // 0. tap 被系统超时禁用后的降级入口。漏掉它，表现是"功能莫名静默失效"。
        interruptSub = context.inputBus.subscribeToInterruptions { [weak self] in
            self?.previousState = nil
        }

        // 1. 输入订阅（.accessibility 已由基座门控保证）
        clickSub = context.inputBus.subscribeToClick { [weak self] click in
            guard let self, let context = self.context else { return }

            // 2. 需要 AX 的判断放进 performBackground，不在主线程阻塞
            Task {
                let info = try? await context.performBackground {
                    // 闭包内是插件自己的系统调用，基座只提供线程
                    WindowProbe.query(pid: click.frontmostPID, at: click.location)
                }
                // 3. Task 继承 @MainActor 隔离，结果已在主线程
                self.handle(info)

                // 4. 可选的快捷反馈（走基座统一出口，自动节流）
                context.notifier.post(PluginNotification(
                    id: "click",
                    title: "已处理",
                    body: "点击位置 \(click.location)",
                    priority: .low,
                    coalescingKey: "click-feedback"
                ))
            }
        }

        // 5. 快捷键（组合键由插件决定并自行持久化，冲突则抛出，由本插件的设置页处理）
        let spec = context.store.value(HotKeySpec.self, forKey: "hotkey") ?? .defaultDemo
        try context.hotKeys.register(spec) { [weak self] in
            self?.toggle()
        }
    }

    func deactivate() {
        clickSub?.cancel()      // 可省略，基座会强制清理；显式写更清晰
        interruptSub?.cancel()
        clickSub = nil
        interruptSub = nil
        previousState = nil     // 必须清理自己的临时状态
        context = nil
    }

    // 设置页是实例方法：本次状态（半填的参数、正在录制的键）都在 self 上，不会因切换页面丢失
    func makeSettingsView() -> AnyView {
        guard let settingsModel else { return AnyView(Text("插件未激活")) }
        return AnyView(DemoSettingsView(model: settingsModel))
    }

    private func toggle() { /* ... */ }
    private func handle(_ info: WindowInfo?) { /* ... */ }
}
```

---

## 6. 基座机制

### 6.1 生命周期与状态机

```swift
@MainActor
public final class PluginRegistry {
    public enum State: Equatable {
        case disabled                              // 用户关闭（默认态）
        case missingCapabilities(Set<Capability>)  // 所需能力未授予
        case active
        case failed(String)                        // activate 抛错
    }
}
```

```
   ┌──────────┐ 用户开启（能力缺失）┌──────────────┐  能力齐备   ┌──────────┐
   │ disabled │───────────────────→│ missingCaps  │───────────→│  active  │
   └──────────┘                    └──────────────┘            └────┬─────┘
        ▲                                 ▲                       │
        │                                 │      权限被收回         │
        │                                 └───────────────────────┘
        │                                                         │
        │ 用户关闭                                    activate 抛错 │
        │                                                         ▼
        └──────────────┬───────────────────────────────→  ┌────────┐
                       │                                  │ failed │
                       └──────────── 用户关闭 ─────────────└────────┘
```

「用户开启且能力齐备」可直接落到 `active`，图中拆成 `disabled → missingCaps → active` 两步，只是为了让"能力判定"这条边显式可见。

**完整迁移表**（图中省略的边以此为准）：

| 当前状态 | 触发 | 目标状态 | 基座动作 |
|---|---|---|---|
| `disabled` | 用户开启，能力齐备 | `active` | 实例化 → `activate` |
| `disabled` | 用户开启，能力缺失 | `missingCapabilities` | 不实例化、不订阅、不弹框 |
| `missingCapabilities` | `didBecomeActive` 重探测后能力齐备 | `active` | 实例化 → `activate` |
| `missingCapabilities` | 重探测后仍缺失 | `missingCapabilities` | 停留，UI 显示「去授权」 |
| `active` | `activate` 抛错 | `failed(String)` | 记日志，不影响其他插件 |
| `active` | **权限被收回** | `missingCapabilities` | `deactivate` + 强制取消全部订阅（§6.2 规则 3） |
| `active` / `missingCapabilities` / `failed` | 用户关闭 | `disabled` | 有实例则 `deactivate`，无实例则无动作 |
| `failed` | 用户重新开启 | 按能力重新判定 | 重新走实例化流程，不做失败缓存 |

**开关策略（全部功能一致）**：

- 每个插件恰好一个启用开关，由基座渲染，**插件无权隐藏自己的开关**。
- 新接入插件默认 `disabled`。理由：与 P2 一致——用户未显式启用前，不申请权限、不创建订阅。
- 关闭所有插件是**合法状态**，基座回到 §1.1 的空载定义。
- 插件内部可以有更细的子开关（在自己的设置页内），但基座只管一层：**启用 / 未启用**。

**生命周期行为**：

| 行为 | 规则 |
|---|---|
| `activate` 幂等 | 由基座侧状态检查保证，插件无需防御 |
| `deactivate` 幂等 | **插件**必须保证，且不得抛错 |
| 全局关闭顺序 | 按注册逆序执行 |
| 权限变化 | `NSApplication.didBecomeActiveNotification` 时重探测，驱动 `missingCapabilities ↔ active` 自动迁移（用户去系统设置授权后无需重启） |
| 失败隔离 | 单个插件 `activate` 抛错只影响自己，其他插件照常 |

### 6.2 权限门控与权限页

#### 权限页（纯基座必含）

基座的权限页是**应用级的唯一权限入口**，任何插件都不需要自己实现权限 UI。

```
┌────────────────────────────────────────────────────────┐
│ 权限                                                    │
│                                                        │
│ 辅助功能          已授权 ✓                              │
│ 用于读取窗口与执行窗口操作            3 个插件正在使用   │
│                                                        │
│ 输入监控          未授权    [ 授权 ]  [ 打开系统设置 ]   │
│ 用于监听鼠标与键盘输入                2 个插件需要       │
│                                                        │
│ 屏幕录制          未授权    [ 授权 ]  [ 打开系统设置 ]   │
│ 用于捕获窗口画面                      1 个插件需要       │
│                                                        │
│ ── 非必需授权 ────────────────────────────────────      │
│                                                        │
│ 通知              未授权    [ 授权 ]  [ 打开系统设置 ]   │
│ 用于发送操作结果提示（被拒时静默降级）  2 个插件使用     │
│                                                        │
│ ⓘ 授予后无需重启应用，返回本窗口即自动生效。             │
└────────────────────────────────────────────────────────┘
```

设计要点：

- **三态而非两态**：`已授权` / `未授权` / `受限`（`restricted`，被 MDM 或系统策略禁用，此时按钮应禁用并说明原因，而不是给一个点了没反应的按钮）。
- 每行显示**用途说明 + 当前有多少个启用插件需要它**。这是让用户理解"为什么这个应用要这个权限"的最低成本方式；数字为 0 时显示"当前无插件使用"。
- 按钮策略：从未申请过 → 「授权」调用 `request`；已申请被拒 → 直接「打开系统设置」（此时系统不会再弹框，`request` 是无效操作）。
- 底部必须注明"无需重启"，因为 macOS 的权限变更存在"已运行的进程不重新读取"的常见误解。
- **权限分两组呈现**：三项 Capability（缺失会阻止插件启动）与「通知」（缺失仅降级）。分组是为了让用户理解"哪些是必须给否则功能不可用，哪些不给也能用"（§6.8）。

#### 门控实现

```swift
@MainActor
public final class PermissionGate {
    public func status(of capability: Capability) -> Bool
    public func isRestricted(_ capability: Capability) -> Bool
    public func refresh()                        // 全量重探测
    public func request(_ capability: Capability)
    public func granted(_ set: Set<Capability>) -> Set<Capability>
    public func consumers(of capability: Capability) -> [String]   // 需要它的已启用插件
}
```

规则：

1. 基座启动**不调用** `request`。`request` 的唯一来源是用户点击权限页或插件设置页中的按钮。
2. 同一 Capability 在单次启动内最多触发一次系统弹窗；重复申请只会堆叠对话框，之后改为跳转系统设置。
3. 权限被收回时，相关插件迁到 `missingCapabilities` 并**取消其全部订阅**（不能只标记状态而让订阅继续跑）。
4. 插件**不得**在 `activate` 中调用 `request`。`activate` 只读状态。
5. 权限从无到有后，重探测由 `didBecomeActive` 驱动，插件自动激活，**不重启进程**。

### 6.3 输入总线（InputBus）★ 核心

```swift
@MainActor
public protocol InputBus {
    /// 订阅有效鼠标点击。基座已在 tap 侧完成有效点击判定（时间差 + 位移差）。
    func subscribeToClick(_ handler: @escaping @MainActor (ClickContext) -> Void) -> Subscription

    /// 订阅指针移动（基座已节流：≤60Hz + 位移阈值）。
    func subscribeToPointerMove(_ handler: @escaping @MainActor (CGPoint) -> Void) -> Subscription

    /// 订阅键盘事件。
    func subscribeToKey(
        _ filter: KeyFilter,
        syncIntercept: (@Sendable (KeyEvent) -> KeyIntercept)?,
        handler: @escaping @MainActor (KeyEvent) -> Void
    ) -> Subscription

    /// 订阅输入源降级通知。这是"事件突然静默消失"时插件唯一能被通知到的途径，
    /// 有进行中会话（按住未完成、拖拽中途）的插件必须订阅。
    func subscribeToInterruptions(_ handler: @escaping @MainActor (InputInterruption) -> Void) -> Subscription
}

public struct InputInterruption: Sendable {
    public let source: InputSource                    // 哪一路输入失效
    public let reason: InterruptionReason             // 为什么失效
    public let recovered: Bool                        // 基座是否已自动重建成功

    public init(source: InputSource, reason: InterruptionReason, recovered: Bool)
}

public enum InputSource: Sendable, Hashable { case keyboard, pointer }
public enum InterruptionReason: Sendable, Hashable { case timeoutDisabled, permissionRevoked, tapCreationFailed }

public final class Subscription { public func cancel() }
```

**按需创建**：总线内部按输入源分别维护引用计数（键盘 tap / 鼠标 tap / 指针监听各一个）。第一个订阅者出现时创建，最后一个订阅者取消时销毁。**零订阅者 = 零 tap**，这是 §1.1 空载定义的实现依据。`subscribeToInterruptions` 不参与引用计数——它挂在基座内部的失效广播上，本身不产生任何系统资源。

#### 契约

| 项 | 约定 |
|---|---|
| 线程 | 四个 `subscribe` 方法都必须在 Main Actor 调用；handler 也在 Main Actor 执行 |
| 回调顺序 | 按订阅先后顺序串行调用，同一插件内多个订阅互不感知 |
| 重复订阅 | 允许。同一插件可对同一事件类型建立多个订阅，各自独立，各自计引用数 |
| **强制清理** | `deactivate()` 返回后，基座**强制取消该插件的全部订阅**（含中断订阅），无论插件是否调用了 `cancel()`。插件主动取消是良好习惯，但忘记也不会泄漏 |
| 引用计数 | 只有订阅本身计数，与插件是否 `active` 无关。插件被关闭 → 其订阅被清理 → 计数下降 → 归零则销毁 tap |
| 点击判定 | 时间差与位移差阈值由基座内部定义（判定"一次有效点击"），**不作为 API 参数暴露**。插件拿到的一定是判定后的事件，并附带 `button` / `clickCount`（§4.4.3） |
| 指针移动节流 | 基座统一节流（≤60Hz + 位移阈值），插件无法关闭。这是防止插件拖慢主线程的最后一道闸 |
| tap 失效 | 系统超时禁用 tap 时，基座自动重新 enable 并通过 `subscribeToInterruptions` 广播 `InputInterruption(source:reason:recovered:)`。插件据此清理"进行中"的临时状态 |
| 权限收回 | `.inputMonitoring` 被收回 → 键盘订阅失效；`.accessibility` 被收回 → 点击与指针订阅失效。两种情况都广播 `permissionRevoked` 并把相关插件迁到 `missingCapabilities`（§6.2、§5.4） |
| `Subscription` | 幂等：重复 `cancel()` 安全；`cancel()` 之后 handler 不再被调用。引用类型（`final class`），复制句柄与否都不影响语义 |

**为什么强制清理是必需的**：插件作者最容易犯的错误是在 `deactivate` 里漏掉取消订阅。若不强制清理，一次开关切换就可能导致 tap 引用计数永远不归零，空载承诺（§1.1）被静默破坏，且现象极难排查——表现为"关掉所有插件后 CPU 仍有异常占用"。

**三类事件源与其模式**：

| 事件源 | 实现 | 模式 | 理由 |
|---|---|---|---|
| 鼠标按下/抬起 | `CGEvent` tap | `.listenOnly` | 绝不介入原生 Dock 悬停与点击语义 |
| 键盘按下/抬起 | `CGEvent` tap | `.defaultTap` | 需要拦截能力（见下） |
| 指针移动 | `NSEvent.addGlobalMonitorForEvents` | 只读监听 | 移动事件QPS极高，绝不能进 Event Tap；且必须节流（建议 ≤60Hz + 位移阈值） |

**键盘三段式回调**——本设计最关键的技术决策：

```swift
/// 阶段一（tap 线程，同步）：预筛。
/// 只允许读标量 + 位运算 + 常量表查找。
/// 禁止：内存分配、NSLock、Dispatch、访问 NSObject / NSRunningApplication。
public struct KeyFilter: Sendable {
    public let keyCodes: Set<Int64>
    public let requiredFlags: CGEventFlags   // 包含语义：事件 flags 必须 ⊇ 此集合
    public init(keyCodes: Set<Int64>, requiredFlags: CGEventFlags = [])
}

/// 阶段二（tap 线程，同步）：拦截决策。仅需要吞事件的功能实现它。
public enum KeyIntercept: Sendable { case passthrough, consume }

/// 阶段三（main actor，异步）：业务逻辑，无法再影响原始事件。
public typealias KeyHandler = @MainActor (KeyEvent) -> Void
```

为什么必须拆三段：

- 只有阶段三触及插件状态与 AppKit，因此**有状态业务永远不阻塞系统输入**。
- 但"按住修饰键期间吞掉某键"这类需求（如 `⌘Q` 自动重复、`⌘Tab` 循环）**必须同步返回 `nil`** 才有效，无法异步决定。
- 若让阶段二回主线程取状态再决定，会造成键盘卡顿甚至死锁。因此阶段二被严格限制为**无锁读取标量**，所需状态一律通过基座提供的 `AtomicFlag`（基于原子指令的无锁封装，不引入任何锁竞争）表达。
- 阶段一、二的实现代码**只存在于 `PluginKit` 内部**；插件只能提供声明式 `KeyFilter` 与 `@Sendable` 的 `syncIntercept` 闭包，编译期即阻止其捕获可变引用状态。

**关于"无队列跳转"的准确含义**：阶段三的投递必然需要一次 `DispatchQueue.main.async`。这是 tap 线程上**唯一允许**的队列跳转，且只发生在回调尾部、只投递值类型。§7 的"无队列跳转"约束指的是阶段一/二内部——不得为了做决策而阻塞等待主线程。两者不矛盾，但必须在实现时区分开，否则要么死锁、要么误以为无法投递。

**tap 存活保障**：必须处理 `CGEventType.tapDisabledByTimeout` —— 回调超时后系统会静默禁用 tap，若不检测并重新 enable，表现为"功能突然不工作"且无任何提示。除重新 enable 外，基座还通过 `subscribeToInterruptions` 广播 `InputInterruption`（`reason: .timeoutDisabled`，`recovered` 标明重建是否成功），避免插件在失效期间静默丢事件。

### 6.4 快捷键仲裁与自定义

**结论：快捷键完全由插件自定义，用户可在插件设置页内改键。基座只负责仲裁与提供录键控件。**

#### 为什么注册权仍必须在基座

全局快捷键是**同一命名空间**：两个插件注册同一组合键时，系统层面只有一个生效且顺序不可控。若各插件自行调用 `RegisterEventHotKey`，冲突表现为"某个功能莫名其妙不响应"，且双方都无法感知对方存在，无法给出任何提示。因此注册动作必须收归基座，但**组合键的内容由插件决定**。

#### 权限说明（避免插件错误声明）

`RegisterEventHotKey`（Carbon）**不需要**辅助功能权限，也**不需要**输入监控权限。它是系统提供的快捷键分发机制，与应用是否持有任何特权无关。

因此：**只使用快捷键的插件，其 `requiredCapabilities` 可以为空集**。只有真正需要监听原始键盘事件（Event Tap）的插件才需要 `.inputMonitoring`。这一点必须在插件开发文档中显著标注——错误声明权限会导致用户被无谓地要求授权，直接损害信任。

#### 接口

```swift
/// Codable 是必需的：插件要把它存进自己的 PluginStore（§6.5、§6.4 规则「快捷键持久化」）。
public struct HotKeySpec: Hashable, Codable, Sendable {
    public let keyCode: UInt32                 // 虚拟键码（kVK_*）
    public let modifiers: HotKeyModifiers      // 必须至少包含一个修饰键
    public init(keyCode: UInt32, modifiers: HotKeyModifiers)
}

/// 修饰键集合。同样必须 Codable——它随 HotKeySpec 一起落盘。
public struct HotKeyModifiers: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32)
    public static let command, option, control, shift: HotKeyModifiers
}

public enum HotKeyAvailability: Sendable {
    case available
    case takenByPlugin(ownerID: String, title: String)
    case takenBySystem                          // 被系统或其他应用占用
    case invalid(reason: String)                // 无修饰键、纯修饰键、无效组合
}

public enum HotKeyError: Error {
    case conflict(ownerTitle: String)
    case reservedBySystem
    case invalid(String)
}

@MainActor
public protocol HotKeyArbitrator {          // 基座内部
    func register(_ spec: HotKeySpec, owner: String, handler: @escaping @MainActor () -> Void) throws
    /// 不含 handler：改键只换组合键，原 handler 继续有效（与 HotKeyService.update 语义一致）
    func update(owner: String, to spec: HotKeySpec) throws
    func unregisterAll(owner: String)
    func availability(of spec: HotKeySpec, requester: String) -> HotKeyAvailability
    func ownerDescription(of spec: HotKeySpec) -> String?
}
```

#### 插件自定义快捷键的正确姿势

```swift
// 在 activate 中：从自己的 store 读取用户上次设定的键（插件持久化，非基座）
let spec = context.store.value(HotKeySpec.self, forKey: "hotkey") ?? .defaultToggle
try context.hotKeys.register(spec) { [weak self] in self?.toggle() }

// 设置页需要 Binding，因此 spec 必须是插件 model 上的可写属性（计算属性取不到 $）
@Observable
final class DemoSettingsModel {
    var spec: HotKeySpec                    // 初值从 store 读
    init(store: PluginStore) { spec = store.value(HotKeySpec.self, forKey: "hotkey") ?? .defaultToggle }
}

// 视图里：改键时原子替换
HotKeyRecorder(
    spec: $model.spec,                                       // 真实 Binding
    availability: { context.hotKeys.availability(of: $0) },   // 调用者身份由 context 决定
    onCommit: { newSpec in
        try context.hotKeys.update(newSpec)                   // 抛错则控件自动回滚，旧键继续生效
        context.store.set(newSpec, forKey: "hotkey")
    }
)
```

#### 规则

| 规则 | 说明 |
|---|---|
| 先注册者胜出 | 冲突时后来者**抛错**，不静默覆盖（静默覆盖会让双方用户都以为功能坏了） |
| 注册顺序确定 | 按 `PluginCatalog` 声明顺序，保证每次启动结果一致 |
| 改键原子性 | `update` 先注册新键，成功才注销旧键；失败则保留旧键并抛错，用户界面回到原值 |
| 录键实时校验 | 录制过程中调用 `availability(of:)`，冲突时立即显示"已被「XX」占用"，不等到提交才报错 |
| 快捷键持久化 | **由插件存入自己的 `PluginStore`**，基座不持久化。基座只在内存中维护当前注册表 |
| 插件关闭时 | 基座自动 `unregisterAll(owner:)`，插件无需（也不应）在 `deactivate` 中重复处理 |
| 系统级冲突 | 若 `RegisterEventHotKey` 返回失败（如系统已占用），映射为 `.reservedBySystem` 并提示用户换键，而不是笼统报"注册失败" |

**基座提供的 UI 组件 `HotKeyRecorder`**：捕捉按键、过滤无效组合（必须含修饰键、排除纯修饰键）、实时冲突校验、显示冲突来源。这是基座提供的**控件**而非业务能力，符合 §4.3 边界（它是 UI 复用，不是策略）。

```swift
public struct HotKeyRecorder: View {
    public init(
        spec: Binding<HotKeySpec>,
        availability: @escaping (HotKeySpec) -> HotKeyAvailability,
        onCommit: @escaping (HotKeySpec) throws -> Void
    )
}
```

`onCommit` 抛错时控件自动回退到 `spec` 的原值，并展示冲突原因——插件无需自己实现回滚。

### 6.5 插件存储

```swift
@MainActor
public protocol PluginStore: AnyObject {
    func value<T: Codable>(_ type: T.Type, forKey: String) -> T?
    func set<T: Codable>(_ value: T, forKey: String)
    func removeAll()          // 「重置此插件」
}
```

**必须是协议而不是具体类**：实现（`PluginStoreImpl`）属于 `PluginKit`，而 `PluginAPI` 的定位是"仅 protocol / struct / enum，零实现"（§4.2）。早期草案把 `PluginStore` 写成 `public final class` 放在 `PluginAPI`，同时又在工程结构里规划 `PluginStoreImpl`——`final class` 无法被另一个类型替代，这两者不可能同时成立。

底层为独立 `UserDefaults(suiteName: "<plugin.id>")`。

**suite 名直接用 pluginID，不再加前缀**：id 本身已是反向域名且全局唯一（§5.1），再拼一层 `<bundle-id>.plugin.` 只会得到 `com.foo.plugin.com.example.plugin.window-snap` 这种冗余串，落到磁盘上是 `~/Library/Preferences/` 下一个难以对照的长文件名。直接用 id 得到 `com.example.plugin.window-snap.plist`，一眼能看出属于哪个插件，排查配置问题时省一次翻译。

设计要点：

- **基座不持有任何插件配置的结构定义**。新增插件不修改基座任何代码，这是与"单体 Settings 结构"最本质的差别。
- 基座自身只持久化一份最小配置：`enabledPlugins: Set<String>` 与三项应用级设置（开机自启、菜单栏显示、窗口行为）。
- 插件自行维护 `_schemaVersion` 并处理迁移，基座不介入。
- **无历史配置迁移**：本设计为全新基线，不存在旧格式，因此不实现任何迁移逻辑（明确的范围裁剪）。

### 6.6 设置界面容器

```
┌──────────────────┬────────────────────────────────────┐
│ 通用             │                                    │
│  ├ 开机自启      │   [选中插件] 的设置视图             │
│  ├ 菜单栏显示    │                                    │
│  └ 启动时显示窗口 │   由插件通过 makeSettingsView()      │
│                  │   提供，基座仅负责容器与布局         │
│ 插件             │                                    │
│  ├ ○ 插件 A  1.0 │                                    │
│  ├ ● 插件 B  1.2 │                                    │
│  └ ○ 插件 C  0.9 │                                    │
│                  │                                    │
│ 权限             │                                    │
│  ├ 辅助功能       │                                    │
│  │   已授权 ✓     │                                    │
│  ├ 输入监控       │                                    │
│  │   未授权 [授权]│                                    │
│  └ 屏幕录制       │                                    │
│      未授权 [授权]│                                    │
│                  │                                    │
│ 关于             │                                    │
└──────────────────┴────────────────────────────────────┘
```

**职责划分**：

| 元素 | 归属 | 说明 |
|---|---|---|
| 插件列表、每个插件行的开关 | 基座 | 插件不得隐藏自己的开关 |
| 每个插件行的名称 / 版本 / 权限徽章 / 状态 | 基座 | 由 `manifest` 驱动，无需插件渲染 |
| 空的 detail 区域 | 基座 | 显示空态引导（含"尚未安装任何插件"文案） |
| 未启用 / 缺权限 / 失败时的 detail | 基座 | 统一呈现原因与「去授权」/「重试」动作，**不加载插件视图** |
| 已启用插件的 detail | 插件 | `makeSettingsView()`（实例方法，状态在插件对象上） |
| 权限总览 | 基座 | 全量 Capability 状态 |

**关键约束**：插件视图只在 `active` 状态下构建。原因是在半初始化或权限缺失时构建插件 UI，极易触发插件内部的隐式假设崩溃（无隔离，见 §3.3）。

**关于"卸载"**：静态链接插件的代码无法移除，因此 UI **不提供**「卸载」按钮，只提供「重置此插件配置」。诚实地呈现能力边界，好过给出一个假的卸载按钮。

### 6.7 版本管理

基座管理插件版本，但必须清楚版本在静态模型下能做到什么：

| 字段 | 用途 | 是否影响加载 |
|---|---|---|
| `manifest.version` | 列表展示、日志、问题定位 | 否 |
| `manifest.minHostVersion` | **构建期**校验：插件要求的最低基座版本 | 是（构建期） |
| `context.hostVersion` | 极少数运行时分支持景 | 否 |

`minHostVersion` 的校验发生在 CI：构建脚本读取全部 `manifest`，与基座当前版本比对，不满足则**构建失败**。这是静态模型下版本约束的唯一真实落点——因为插件与基座永远同一次编译、同一次发版，不存在"旧基座加载新插件二进制"的场景。

因此明确**不启用** `BUILD_LIBRARY_FOR_DISTRIBUTION`，不承担 library evolution 的开发成本（resilient struct、禁 `@frozen`、enum 兼容处理）。不要在版本号上构建任何运行时逻辑。

### 6.8 通知服务

#### 一个容易被忽略的事实：通知授权不是 TCC

三项 Capability 走 TCC（系统设置 → 隐私与安全性），而通知走 `UNUserNotificationCenter`，是**独立的授权体系**：

- 需要显式 `requestAuthorization(options:)`，用户首次会被询问
- 用户可能拒绝，拒绝后只能去「系统设置 → 通知」修改
- 它**不体现在 TCC 授权面板**，也不受辅助功能/输入监控状态影响

因此明确设计决策：**通知授权不作为 `Capability`**。理由是语义不同——Capability 缺失会阻止插件 `activate`，而通知被拒时插件应当照常工作，只是不发通知。把两者混在一个枚举里会导致"因为用户关了通知，整个插件不可用"这种荒谬结果。

但用户仍需能看到它的状态，所以**权限页中单独列出「通知」一行**，标注"非必需权限，被拒时相关功能静默降级"。

#### 接口

```swift
@MainActor
public protocol Notifier {
    /// 当前授权状态（.notDetermined / .denied / .authorized）
    var authorization: NotificationAuthorization { get }

    /// 请求授权。基座全局只申请一次；重复调用返回既有状态，不重复弹框。
    /// 仅允许在用户手势中调用。
    func requestAuthorization() async -> Bool

    /// 发送一条通知。节流、去重、前台抑制全部由基座处理。
    func post(_ notification: PluginNotification)
}

public struct PluginNotification {
    public let id: String                        // 插件内唯一，用于替换同一条通知
    public let title: String
    public let body: String
    public let priority: NotificationPriority    // .normal / .low
    public let coalescingKey: String?            // 相同 key 在窗口期内只保留最新一条
    public let onClick: (@MainActor () -> Void)? // 可选；仅插件 active 时有效

    public init(id: String, title: String, body: String,
                priority: NotificationPriority = .normal,
                coalescingKey: String? = nil,
                onClick: (@MainActor () -> Void)? = nil)
}

public enum NotificationPriority { case normal, low }
public enum NotificationAuthorization { case notDetermined, denied, authorized }
```

#### 节流与抑制规则（基座实现，插件不可配置）

| 规则 | 值 | 理由 |
|---|---|---|
| 同插件最小间隔 | 5 秒 | 防止插件在事件循环里连发 |
| 全局速率上限 | 1 条 / 2 秒，且 1 分钟内最多 10 条 | 防止多插件同时轰炸 |
| 超限处理 | **直接丢弃并记日志**，不排队 | 排队会在稍后一次性涌出，体验更差 |
| 前台抑制 | 基座设置窗口为 key window 时不弹横幅 | 用户正在看设置，横幅是噪音 |
| 合并窗口 | 相同 `coalescingKey` 在 60 秒内只保留最新一条 | 典型场景："已最小化 N 个窗口"这类高频状态通知 |
| 点击时插件非 active | 忽略点击并记日志 | 插件可能已被用户关闭，强行激活违背用户意图 |

#### 日志

- 统一走 `context.logger`，自动标注 `pluginID` 与时间戳。
- **分级**：`debug` / `info` / `warning` / `error`。`debug` 仅在内部构建输出，Release 不落盘。
- **禁止记录敏感内容**：窗口标题、文件路径、剪贴板、用户输入一律不得写入日志。诊断包会被用户导出并可能公开贴出，这是最常见的隐私泄漏途径。
- 基座侧可导出诊断包（应用版本 + 插件列表与版本 + 权限状态 + 最近 N 条日志），这是无崩溃隔离时的关键排障手段。

### 6.9 应用壳层：名称、图标、版本与关于页

壳层是纯基座阶段**唯一有实质内容的交付物**，必须在 M0 完整可交付，且**不得硬编码**任何身份信息。

#### 应用身份

| 项 | 来源 | 约束 |
|---|---|---|
| 名称 | `Bundle.main.object(forInfoDictionaryKey: "CFBundleName")` | 全部界面文案引用该值，不出现字面量 |
| 图标 | `Assets.xcassets/AppIcon.appiconset` | 完整 16/32/128/256/512 及 @2x，macOS 圆角矩形规范 |
| 菜单栏图标 | `Assets.xcassets` 内的 Template Image | **必须为 template image**，以自动适配浅色/深色/强调色菜单栏 |
| 版本号 | `CFBundleShortVersionString` | 形如 `1.0.0`，营销版本 |
| 构建号 | `CFBundleVersion` | 递增整数，用于区分同版本的不同构建 |
| Bundle ID | `CFBundleIdentifier` | 系统身份；**不**用作插件存储键的根（§6.5 直接用 pluginID 作 suite 名） |
| 版权 | Info.plist `NSHumanReadableCopyright` | 关于页展示 |

版本号来源必须是 **Info.plist 的构建配置变量**（如 `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`），不在代码中写死——否则每次发版都要改源码，且必然出现漏改。

#### 关于页

```
┌─────────────────────────────────────┐
│            [应用图标 96pt]           │
│                                     │
│            <名称>                    │
│         版本 1.0.0 (42)              │
│                                     │
│      <一句话描述，来自 Info.plist>    │
│                                     │
│   基座版本        1.0.0              │
│   插件            3 个已启用 / 5 个   │
│                                     │
│   [ 导出诊断信息 ]   [ 检查更新 ]     │
│                                     │
│   © 2026 <版权方>                    │
└─────────────────────────────────────┘
```

要素说明：

- **应用版本**与**基座版本**在纯基座阶段相同，但概念要分开——未来若插件独立发版，两者会分离。分开呈现可避免届时改 UI。
- **插件统计**让用户一眼看到"当前装了几个、开了几个"，这是插件化产品的必要透明度。
- **导出诊断信息**输出：应用版本/构建号、插件列表（ID + 版本 + 状态 + 需要的能力）、三项 Capability 状态 + 通知授权状态、最近 N 条日志。无崩溃隔离时这是排障的第一手材料。
- 检查更新在 M0 可只做占位（打开官网/Release 页），不必实现真正的更新器。

#### 通用页（纯基座必含）

| 项 | 实现要点 |
|---|---|
| 开机自启 | `SMAppService.mainApp.register()/unregister()`；注册可能失败，必须捕获并把开关状态回滚为真实状态，不能出现"UI 显示已开启但实际未注册" |
| 菜单栏显示 | 关闭后仍需保留打开设置窗口的途径（如 Dock 图标或再次启动应用时显示窗口），否则用户会把自己锁在外面 |
| 启动时显示设置窗口 | 首次启动/无插件时的引导 |
| 退出 | 明确的「退出」按钮，位置符合 macOS 设置窗口惯例 |

**"把自己锁在外面"是这类工具最常见的可用性事故**：用户关闭菜单栏图标后应用彻底不可达，只能强杀。必须在关闭菜单栏显示时校验"是否还有其他途径能打开设置窗口"，若没有则拒绝关闭或给出说明。

---

## 7. 线程模型

| 上下文 | 承载内容 | 约束 |
|---|---|---|
| **Tap 线程**（每个 tap 一条专用 `Thread`，`.userInteractive`） | `KeyFilter` 预筛、`syncIntercept`、`AtomicFlag` 读取、构造 `KeyEvent` / `ClickContext` 值 | 只做位运算/查表；无分配、无锁、不访问 AppKit；唯一允许的队列跳转在回调尾部 |
| **Main Actor** | 插件 `activate`/`deactivate`、全部订阅 handler、全部 UI、`makeSettingsView` | 唯一可触碰 AppKit / SwiftUI / 插件状态的位置 |
| **后台执行队列**（基座内部串行队列） | 插件经 `performBackground` 提交的跨进程同步调用 | 插件**不得**在 Main Actor 上直接发起 AX / 窗口枚举 / 同步捕获，也不得自建队列 |
| **插件自有异步** | 插件用 `Task` 发起的捕获等异步工作 | 结果必须回到 Main Actor 再更新状态 |
| **通知/文件 IO** | 日志落盘 | 基座内部，插件不可见 |

**核心规则**：

1. 插件**拿不到**任何线程创建 API，也**拿不到** `CGEvent` 对象——输入事件一律以值类型（`KeyEvent` / `ClickContext`）的形式投递到 Main Actor。
2. `performBackground` 的闭包签名标注 `@Sendable`，编译期阻止其捕获 Main Actor 上的可变状态，从而消除"后台队列访问 UI 状态"这类竞争。
3. `@MainActor` 标注在插件协议上，插件代码默认全部在主线程，仅显式 `async` 方法会离开。

**tap 线程上到底什么能做、什么不能做**（这条最容易写错，因为它看起来自相矛盾）：

| 操作 | 允许 | 说明 |
|---|---|---|
| 读 `AtomicFlag` / 原子 pid | ✅ | 无锁标量读 |
| 位运算、常量表查找 | ✅ | |
| 构造 `KeyEvent` / `ClickContext` 等小结构 | ✅ | 纯值类型，不触碰堆，不涉及 ARC |
| 回调尾部 `DispatchQueue.main.async` 投递一次 | ✅ | 仅投递值类型；这是三段式阶段三的必经路径 |
| `DispatchQueue.main.sync` / `Semaphore.wait` | ❌ | 死锁 |
| `NSWorkspace` / `NSEvent` / 任何 AppKit | ❌ | 前台应用一律以 `frontmostPID` 传递（§4.4.3） |
| 创建数组 / 字典 / 字符串 | ❌ | 堆分配 |
| `NSLock` / `os_unfair_lock` / `DispatchGroup` | ❌ | 不可控等待 |

这张表的意义是把"无分配、无锁、无队列跳转"从一句口号变成可逐条对照 code review 的判据。注意其中"构造 `ClickContext` 是允许的"——它只含 `CGPoint`、整数与 `pid_t`，不产生堆分配；早期草案让它携带 `NSRunningApplication` 时，这一行就不成立了。

**为什么跨进程调用必须经 `performBackground`，而不是插件随手 `DispatchQueue.global()`**：AX 是跨进程同步 IPC，目标应用无响应时单次调用可能阻塞数秒；`CGWindowListCopyWindowInfo` 与同步截图同理。若插件在主线程调用，整个应用的 UI（包括菜单栏）都会冻结；若每个插件各自建队列，则并发调用数与线程数不可控。基座提供单一串行队列，等于把"慢调用不得上主线程"这条约束变成 API 形状。

**串行是有意为之**：多个插件同时查询同一个卡住的应用时，串行队列会让它们排队等待，而不是并发堆积几十个阻塞线程。代价是吞吐，收益是系统整体可预测——在"用户正在操作电脑"的场景里，可预测比吞吐重要。

---

## 8. 启动时序

```
1. 加载基座自身最小配置（enabledPlugins + 应用级设置）
2. 从 PluginCatalog 读取全部 manifest（不实例化）
3. 渲染设置窗口数据源 & 菜单栏图标
4. 对每个 enabled 插件：
   a. PermissionGate 检查 requiredCapabilities
   b. 缺失 → state = missingCapabilities（不 activate、不订阅、不发任何请求）
   c. 齐备 → 实例化 → activate(context)
       c1. 插件向 InputBus 订阅 → 总线按需创建 tap
       c2. 插件向 HotKeyArbitrator 注册 → 冲突则抛错
               ↓
            成功 → active
            抛错 → failed（捕捉并呈现，不影响其他插件）
5. 注册 didBecomeActive 监听，用于权限变化重探测
```

**空载分支**：步骤 4 的 `enabled` 集合为空时，流程在第 4 步直接结束——不创建 tap、不检查权限、不实例化任何插件对象。此时进程只持有：一个菜单栏图标、一个可打开的设置窗口、一份配置。

**用户打开某插件开关时的增量流程**（与启动流程的 4-a~4-c 一致，不重启进程）：

```
Toggle ON  → 能力检查 → 缺失则行尾显示「去授权」（不弹框）
                      → 用户点击「去授权」→ PermissionGate.request（此处才可能弹系统框）
                      → 授权后 didBecomeActive 重探测 → 自动 activate
Toggle OFF → deactivate → 取消全部订阅 → 引用计数归零则销毁 tap
```

---

## 9. 安全模型

### 9.1 威胁面

基座进程持有辅助功能授权，等价于完整的用户态控制能力（模拟任意输入、读取任意窗口内容、控制任意应用）。

由于插件全部为**内部自研 + 同一 Team 签名 + 同工程编译 + 静态链接**，攻击面与不含插件的应用**完全一致**，未引入新的暴露面。这是 §3.5 三个结论的直接收益。

### 9.2 结构性防护及其真实强度

**必须先承认一件事：既然基座不封装系统 API（§4.4），大部分"防护"就只是约定，不是强制。**

插件随时可以自己 `import CoreGraphics` 建 Event Tap、自己调 `AXIsProcessTrustedWithOptions(prompt:)` 弹框、自己发通知。基座对此没有任何编译期或运行时手段。

如实记录每条约束的真实强度，避免后续维护者误以为有保证：

| 约束 | 手段 | 真实强度 | 违反后果 |
|---|---|---|---|
| 插件不得依赖 `PluginKit` | SwiftPM target 依赖声明 | **编译期强制** | 构建失败 |
| 插件之间互不可见 | 独立 module + `internal` | **编译期强制** | 编译失败 |
| 插件不得在主线程发起 AX 调用 | `performBackground` 的 `@Sendable` 签名 | **部分编译期**（只阻止捕获 Main Actor 状态，不阻止绕过它） | UI 冻结 |
| 插件只用一个 Event Tap | 只能靠 `context.inputBus` | **约定** | 输入延迟随插件数累积恶化，且难排查 |
| 插件申请权限走统一入口 | 只能靠 `context.permissions.request` | **约定** | 对话框堆叠，用户无法归因 |
| 插件通知走统一出口 | 只能靠 `context.notifier.post` | **约定** | 打扰用户 |
| 插件配置不互相污染 | 独立 `UserDefaults` suite | **约定**（插件也可写任意 suite） | 配置互相覆盖 |

**唯一真正强制的只有"模块可见性"这一类。** 其余全部依赖开发者自律与 code review。

**为什么这个取舍可以接受**：

1. 威胁模型是"**内部开发者写错**"，不是"恶意第三方"。同 Team 签名、同仓库、同一次代码审查，与新增一个文件的风险等级相同。
2. 反过来，若为了强制这些约束而封装系统 API，会引入一个更严重的问题：基座需要预测所有插件需求，接口无限膨胀，最终每个插件都要改基座——**架构退化为单体**，这才是真正的失败。
3. 该付出的成本应该是"让正确做法更容易"，而不是"让错误做法不可能"。`context.inputBus`、`context.permissions` 用起来比自己造轮子更省事，这就是设计上的引导。

**推论：如果未来接入外部来源的插件，这套防护必须整体作废重建**（§13 的进程外化 + 能力收窄 + 签名白名单）。那不是"加固现有设计"，而是**更换威胁模型**。不能靠给现有 API 加限制来解决——因为它们本就没有强制力。

**CI 兜底检查**（只拦得住疏忽，拦不住刻意）：

| 检查 | 能拦住什么 |
|---|---|
| `Plugins/*` 不得依赖 `PluginKit` | 误改 Package.swift |
| `Plugins/*` 出现 `CGEvent.tapCreate` / `CGRequestScreenCaptureAccess` / `AXIsProcessTrustedWithOptions` 字面调用 | 复制粘贴式违规 |
| 全部 `manifest.minHostVersion` 与基座版本比对 | 版本错配（§6.7） |
| 全部插件的 `requiredCapabilities` 与其实际 import 的框架是否匹配 | 声明与实现不符 |

### 9.3 隐私与用户预期

- 基座启动过程零权限请求，用户首次安装后不会看到任何弹框。
- 每个权限的申请时机必须可归因到一次明确的用户点击（权限页按钮，或某个插件设置页内的按钮）。
- 权限页常驻展示三项授权状态 + 用途说明 + "当前有多少个启用插件需要它"，用户随时可查。
- 插件被关闭时，其所需权限若不再被任何启用插件使用，基座不主动撤销（系统不支持自动撤销），但应在权限页标注"当前无插件使用"。
- 关于页展示已安装/已启用插件数量，保持插件化产品的透明度。

---

## 10. 工程结构

```
ProjectRoot/
├── Package.swift                      # SwiftPM：本地包 + 可执行目标
├── Packages/
│   ├── PluginAPI/                     # 纯协议层，零实现，零依赖
│   │   └── Sources/PluginAPI/
│   │       ├── PluginManifest.swift
│   │       ├── FeaturePlugin.swift
│   │       ├── PluginContext.swift
│   │       ├── Capability.swift
│   │       ├── PermissionService.swift
│   │       ├── InputBus.swift          # 含 InputInterruption / InputSource
│   │       ├── HotKey.swift            # 含 HotKeyModifiers
│   │       ├── Notifier.swift
│   │       ├── PluginStore.swift       # 仅协议
│   │       └── PluginLogger.swift      # 刻意不叫 Logger.swift，避免与 os.Logger 混淆
│   ├── PluginKit/                     # 基座机制实现，仅 HostApp 可依赖
│   │   └── Sources/PluginKit/
│   │       ├── PluginRegistry.swift
│   │       ├── PermissionGate.swift
│   │       ├── InputBusImpl.swift
│   │       ├── BackgroundEventTap.swift
│   │       ├── AtomicFlag.swift
│   │       ├── HotKeyArbitrator.swift
│   │       ├── TaskRunner.swift       # performBackground 的串行执行器
│   │       └── PluginStoreImpl.swift
│   ├── PluginSupport/                 # 可选共享工具，纯函数，无状态
│   │   └── Sources/PluginSupport/
│   │       ├── AXQuery.swift          # AX 属性读取便捷函数
│   │       ├── WindowList.swift       # 窗口枚举
│   │       └── Geometry.swift         # 坐标换算（多屏 / 缩放）
│   └── Plugins/                       # 每个插件一个 target
│       └── Harness/                   # 仅 Debug（见 §11）
└── HostApp/
    ├── HostApp.swift                  # 应用入口
    ├── AppInfo.swift                  # 名称/版本/构建号，全部读 Bundle
    ├── PluginCatalog.swift            # 插件注册表（纯基座阶段为空）
    ├── MenuBarController.swift
    ├── SettingsWindow.swift
    ├── Views/
    │   ├── GeneralPane.swift          # 自启 / 菜单栏 / 窗口行为
    │   ├── PluginListPane.swift       # 插件列表 + 开关 + 状态
    │   ├── PermissionPane.swift       # 权限状态 + 授权按钮
    │   ├── AboutPane.swift            # 图标 / 名称 / 版本 / 诊断导出
    │   └── DiagnosticsExporter.swift
    └── Resources/
        └── Assets.xcassets/
            ├── AppIcon.appiconset
            └── MenuBarIcon.imageset   # Template Image
```

> **实现结构补充（M0 落地后）**：插件源码与《插件开发规范》位于**独立仓库** `Chassis-Plugins/`，以同级目录检出（`Chassis/Chassis-Plugins/`），基座仓库通过 `.gitignore` 忽略该目录。根包 `Package.swift` 用路径把 `Chassis-Plugins/Packages/<Plugin>` 编进同一二进制，「注册表即链接清单」与静态链接的收益均不变；`PluginAPI` / `PluginSupport` 独立成包，使插件仓库也能 `swift build` 自检，且不产生包级循环依赖（插件包只依赖接口包，基座只把插件 target 编进根包）。

**SwiftPM 与 Xcode 工程的分工**：`Packages/PluginAPI`（含 C 原子垫片）、`Packages/PluginSupport` 各自是独立包，根包的 `Package.swift` 承载 `PluginKit` 与插件 target（源码位于插件仓库）。`HostApp` 必须是 **Xcode app target**——Info.plist、entitlements、Assets、签名与公证、`LSUIElement` 都无法由 SwiftPM 可执行目标完整提供；它通过本地包依赖引入上述库，并把 `PluginCatalog` 中引用的每个插件 target 加入链接。

这条依赖关系不能省略也不能自动推导：**插件 target 必须出现在 HostApp 的 dependencies 里**，否则 `PluginCatalog` 中的 `MyPlugin.self` 直接编译失败（找不到符号）。这个报错恰好是好事——它保证「注册表即链接清单」，不会出现"注册代码写了但插件没被链接进二进制"的静默丢失。

**工程配置要点**：

| 配置 | 值 | 原因 |
|---|---|---|
| `ENABLE_APP_SANDBOX` | `NO` | 沙盒下无法使用辅助功能 API |
| Hardened Runtime | `YES` | 公证必需；静态链接不涉及 Library Validation |
| `LSUIElement` | `YES` | 常驻菜单栏，不占 Dock |
| `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` | 构建设置 | 版本号唯一来源，代码中不写死（§6.9） |
| `CFBundleDisplayName` | 应用名 | 关于页与系统界面展示 |
| `NSHumanReadableCopyright` | 版权行 | 关于页展示 |
| 最低系统版本 | **macOS 14+** | `@Observable` 宏、`NavigationSplitView`；13 也可行但需退回 `ObservableObject` |

---

## 11. 交付里程碑

### M0 · 纯基座（本期目标）

交付一个**可独立安装使用的完整应用**，不含任何业务功能：

**应用壳层**

- 应用名称、图标（完整尺寸集）、菜单栏 Template 图标
- 版本号与构建号来自构建设置，关于页正确展示
- 菜单栏菜单：打开设置、关于、退出
- `LSUIElement` 常驻，不占 Dock

**设置窗口（四个页面）**

| 页面 | 内容 |
|---|---|
| 通用 | 开机自启、菜单栏显示、启动时显示窗口、退出按钮 |
| 插件 | 插件列表（空态引导）、每个插件的开关 / 版本 / 权限徽章 / 状态 |
| 权限 | 三项 Capability + 通知（分组呈现）、用途说明、授权按钮、跳转系统设置、"无插件使用"标注 |
| 关于 | 图标、名称、版本、构建号、插件统计、导出诊断信息、版权 |

**基座能力（五项，接口与契约已定稿于 §5.5）**

| 能力 | M0 完成标准 |
|---|---|
| `InputBus` | 按输入源分别引用计数；三段式键盘回调；`ClickContext` 含 `button`/`clickCount`/`frontmostPID`；tap 超时自动恢复并通过 `subscribeToInterruptions` 广播 |
| `PermissionService` | 探测 + 收敛申请 + `didBecomeActive` 重探测 + 消费者统计 |
| `HotKeyService` | 注册/更新/注销；冲突检测与 `HotKeyError`；`HotKeyRecorder` 控件 |
| `Notifier` | 授权申请（全局一次）+ 节流 + 去重 + 前台抑制 + 点击分发 |
| `PluginContext.performBackground` | 串行后台队列 + `@Sendable` 闭包约束 |

**其他 M0 交付物**

- `PluginSupport` 骨架（可先只放坐标换算与窗口枚举）
- 启动零权限请求、零 Event Tap、零 AX 调用
- `Plugin-Development-Guide.md` 定稿（M1 的探针插件必须按规范编写，作为首个范例）

**M0 完成的判据**：用户安装后打开设置，能看到自己的应用名与图标、分组的权限状态（三项 Capability + 通知）、一个空的插件列表；点「授权」能弹出对应系统框；点「开机自启」能生效；关掉菜单栏图标后仍能通过再次启动打开设置窗口。

### M1 · 测试插件（验证载体，非产品功能）

纯基座没有功能就无法自证机制正确，因此需要一个**专门用于验证基座的探针插件**：

- ID 固定为 `com.<reverse-dns>.plugin.harness`，**仅在 Debug 构建注册**，Release 不进入 `PluginCatalog`
- 探针分五组，与五项基座能力一一对应：点击/按键/捕获/快捷键/通知
- 每组探针内置"违规对照开关"，用于验证 §12.3-D 组契约（例如：故意不取消订阅，观察 tap 是否仍被回收）
- 作用：作为 `InputBus` 引用计数、`PermissionService` 门控、`Notifier` 节流、`PluginStore` 隔离、三段式回调、快捷键仲裁的测试载体
- **必须严格按 `Plugin-Development-Guide.md` 编写**——它是规范的首个实现样本，也是规范是否可落地的验证

明确：探针插件不是产品功能，不随正式版发布，也不属于"基座内置功能"（P1 未被违反）。

### M2 · 首个真实插件

按业务优先级接入，**基座代码不应再改动**。若接入首个插件需要修改基座，说明 `PluginContext` 抽象不完整，应回补基座而非在插件中绕过。

### M3 · 后续插件

每个插件独立 module、独立配置、独立设置页、独立开关，互不感知。

---

## 12. 验收标准

### 12.1 纯基座（M0）

| 编号 | 判据 | 验证方式 |
|---|---|---|
| A1 | 启动后进程存在 0 个 `CGEvent` tap | 运行时断言 + Instruments |
| A2 | **启动路径** 0 次系统权限弹框（点击权限页按钮弹出属于预期） | 全新用户环境实测 |
| A3 | 启动后 0 次 AX 调用 | `fs_usage` 或代码断点 |
| A4 | 插件列表为空时显示空态，无异常 | 人工 |
| A5 | 全部插件关闭后回到 A1~A3 状态 | 开关测试 |

### 12.2 应用壳层（M0）

| 编号 | 判据 |
|---|---|
| C1 | 关于页、菜单栏菜单、设置窗口标题中的应用名一致，且来自 Bundle 而非硬编码 |
| C2 | 应用图标在 Finder / 关于页 / 通知中显示正常，尺寸集完整 |
| C3 | 菜单栏图标为 Template Image，浅色/深色菜单栏下均清晰 |
| C4 | 版本号与构建号来自构建设置；仅修改 `MARKETING_VERSION` 并重新构建即可正确反映 |
| C5 | 权限页三种状态（已授权 / 未授权 / 受限）显示正确；点「授权」才可能弹系统框 |
| C6 | 权限页显示"当前有几个启用插件需要此权限"，无插件时为"当前无插件使用" |
| C7 | 关闭"菜单栏显示"后，仍能通过其他途径打开设置窗口（不可锁死） |
| C8 | 开机自启注册失败时，开关状态回滚为真实状态，不出现 UI 与系统不一致 |
| C9 | 导出诊断信息包含应用版本、插件列表、权限状态、最近日志 |

### 12.3 机制正确性（M1）

| 编号 | 判据 |
|---|---|
| B1 | 首个订阅创建 tap，最后一个订阅取消销毁 tap（引用计数准确） |
| B2 | 缺权限的插件不 `activate`、不订阅、不弹框，状态为 `missingCapabilities` |
| B3 | 用户去系统设置授权后返回，插件自动变为 `active`（无需重启） |
| B4 | 单个插件 `activate` 抛错不影响其他插件 |
| B5 | 两个插件注册同一快捷键时，后者抛错且前者生效 |
| B6 | 插件 A 无法读取插件 B 的存储 |
| B7 | 非 `active` 状态下不构建插件设置视图 |
| B8 | 改键失败（冲突）时保留旧键，用户界面回到原值，功能不中断 |
| B9 | 录键过程中实时提示冲突来源（"已被 XX 占用"），无需提交才报错 |
| B10 | 仅使用快捷键的插件，`requiredCapabilities` 为空集，启用时不请求任何权限 |
| B11 | 探针在 Main Actor 直接发起 AX 调用时出现可感知 UI 冻结，改为包裹 `performBackground` 后消失（反向验证该契约的必要性） |
| B12 | 探针完全跳过 `PluginSupport`、直接调用系统 API 时，功能正常（验证 `PluginSupport` 确实可选而非隐式依赖） |
| B13 | 在插件设置页改到一半切走再切回，未提交的编辑仍在（验证 `makeSettingsView()` 走的是实例状态，而非静态重建成新 model） |
| B14 | 右键点击与双击能被正确区分（`ClickContext.button` / `clickCount` 与真实输入一致） |
| B15 | 插件拿到 `frontmostPID` 后能自行解析出 `NSRunningApplication`，且该 pid 对应的是"点击前"的前台应用 |

### 12.4 基座能力契约（M1）

五项能力入口的契约（§5.5）逐条验证，这是"接口定义好了"的实际判据：

| 编号 | 判据 |
|---|---|
| D1 | 探针故意不在 `deactivate` 中取消订阅，tap 引用计数仍归零（强制清理生效） |
| D2 | `deactivate` 后插件残留的快捷键被基座自动注销，按下不再触发任何行为 |
| D3 | 同插件 5 秒内连发 3 条通知，只出现 1 条，其余被丢弃并记日志 |
| D4 | 相同 `coalescingKey` 的通知在 60 秒内互相替换而非叠加 |
| D5 | 通知授权被拒时 `post` 不抛错、不崩溃，插件功能照常 |
| D6 | 设置窗口为 key window 期间不发横幅（前台抑制生效） |
| D7 | 插件非 active 时点击历史通知，被忽略并记日志，不激活插件 |
| D8 | 手动禁用 tap（模拟超时）后基座自动重新 enable，且重建过程不改变引用计数 |
| D9 | 权限被收回后，相关插件的订阅全部失效且状态变为 `missingCapabilities` |
| D10 | `HotKeyError.conflict` 能被插件捕获并在其设置页显示冲突来源 |
| D11 | 手动禁用 tap 后，订阅了 `subscribeToInterruptions` 的插件收到一次 `InputInterruption`，`reason` 与实际原因一致，`recovered` 与实际重建结果一致 |
| D12 | 收回 `.accessibility` 后，只订阅了点击/指针的插件失效；只订阅键盘的插件不受影响（验证权限按订阅类型分别门控） |

### 12.5 性能红线

| 指标 | 阈值 | 测量方式 |
|---|---|---|
| 全局键盘 tap 数量 | ≤ 1（与插件数无关） | 运行时断言 |
| 全局鼠标 tap 数量 | ≤ 1 | 运行时断言 |
| 零插件时 tap 数量 | 0 | 运行时断言 |
| 键盘回调常驻路径耗时 | P99 < 100 µs | `mach_absolute_time` 采样 |
| 回调内内存分配 | 0 次 | Instruments Allocations |
| 原生输入与悬停延迟 | 无可感知差异 | A/B 对照 |

---

## 13. 演进边界

本架构刻意**不预留**以下能力，避免为未出现的需求付出复杂度（P5）。表内同时给出触发条件与改造代价，以便未来判断。

| 未来需求 | 触发条件 | 改造路径 | 代价 |
|---|---|---|---|
| 插件独立发布 / 热更新 | 插件数量显著增长或需要灰度 | 转动态 framework + `BUILD_LIBRARY_FOR_DISTRIBUTION` | 需承担 library evolution 契约；需开启 Library Validation 例外 |
| 第三方插件生态 | 出现真实外部开发者诉求 | 进程外化 + 独立授权引导 + 签名白名单 + 能力二次确认 | 用户需多次授权，产品假设失效；需独立安全评审 |
| 插件崩溃隔离 | 出现因插件崩溃导致的口碑问题 | 仅能进程外化 | 同上 |

**判断原则**：只要插件仍自研且随基座一同发版，静态 module 就是成本最低、风险最小的形态。上表中任何一项被触发，都说明插件规模或协作模式已超出该形态的承载范围，届时再做结构性改造——而不是现在就把代价prepay。

---

## 附录 A · 接口定义汇总

> **本附录是 `PluginAPI` 的唯一权威签名**，正文各节为叙述，以这里为准。全部公开 `struct` 均显式声明 `public init`；全部 `enum` 无实现。
> `PluginAPI` 的依赖：`SwiftUI`（`AnyView` / `LocalizedStringKey`）、`Foundation`（`Bundle`）、`CoreGraphics`（`CGEventFlags` / `CGPoint`）。刻意不依赖 `AppKit`——插件拿到的都是值类型，不出现 `NSRunningApplication` 之类跨线程不安全对象。

```swift
// ===== PluginAPI · 元信息 =====

public struct PluginManifest {
    public let id: String                       // 反向域名；发布后不可更改
    public let version: String
    public let minHostVersion: String
    public let title: LocalizedStringKey
    public let summary: LocalizedStringKey
    public let iconSystemName: String
    public let requiredCapabilities: Set<Capability>
    public let optionalCapabilities: Set<Capability>
    public let resourceBundle: Bundle           // 插件自己的本地化资源（§5.1）

    public init(id: String,
                version: String,
                minHostVersion: String,
                title: LocalizedStringKey,
                summary: LocalizedStringKey,
                iconSystemName: String,
                requiredCapabilities: Set<Capability> = [],
                optionalCapabilities: Set<Capability> = [],
                resourceBundle: Bundle)
}

public enum Capability: String, Hashable, CaseIterable, Sendable {
    case accessibility, inputMonitoring, screenCapture
}

// ===== PluginAPI · 插件 =====

@MainActor
public protocol FeaturePlugin: AnyObject {
    static var manifest: PluginManifest { get }

    /// 前置条件由基座保证：用户已开启 + requiredCapabilities 齐备。
    func activate(context: PluginContext) throws

    /// 必须幂等、不得抛错、必须同步完成。基座会强制清理订阅与快捷键，
    /// 但清理不了插件自己的 Timer / Task / NotificationCenter 观察者。
    func deactivate()

    /// 设置页。仅在 active 时调用，可访问 self 上的状态（§5.1、§6.6）。
    func makeSettingsView() -> AnyView
}

@MainActor
public protocol PluginContext: AnyObject {
    var pluginID: String { get }
    var hostVersion: String { get }
    var store: PluginStore { get }
    var inputBus: InputBus { get }
    var hotKeys: HotKeyService { get }
    var permissions: PermissionService { get }
    var notifier: Notifier { get }
    var logger: PluginLogger { get }

    func performBackground<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T
}

@MainActor
public protocol Notifier {
    var authorization: NotificationAuthorization { get }
    /// 全局只申请一次；重复调用返回既有状态，不再弹框。
    func requestAuthorization() async -> Bool
    func post(_ notification: PluginNotification)
}

public struct PluginNotification {
    public let id: String                       // 同 id 覆盖同一条通知
    public let title: String
    public let body: String
    public let priority: NotificationPriority
    public let coalescingKey: String?           // 60s 内相同 key 只保留最新一条
    public let onClick: (@MainActor () -> Void)?

    public init(id: String, title: String, body: String,
                priority: NotificationPriority = .normal,
                coalescingKey: String? = nil,
                onClick: (@MainActor () -> Void)? = nil)
}

public enum NotificationPriority { case normal, low }
public enum NotificationAuthorization { case notDetermined, denied, authorized }

@MainActor
public protocol PermissionService {
    func status(of capability: Capability) -> Bool
    /// 被 MDM 或系统策略禁用：request 必然无效，UI 应说明原因而不是给一个点了没反应的按钮。
    func isRestricted(_ capability: Capability) -> Bool
    var missing: Set<Capability> { get }
    /// 仅限用户手势内调用；每种权限每次启动最多弹一次框。
    func request(_ capability: Capability)
}

@MainActor
public protocol HotKeyService {
    func register(_ spec: HotKeySpec, handler: @escaping @MainActor () -> Void) throws
    /// 只换组合键，handler 不变；失败则保留旧键。
    func update(_ spec: HotKeySpec) throws
    /// 调用者身份由 context 决定，参数里不传 pluginID。
    func availability(of spec: HotKeySpec) -> HotKeyAvailability
    func unregister()
}

public enum HotKeyAvailability: Sendable {
    case available
    case takenByPlugin(ownerID: String, title: String)
    case takenBySystem
    case invalid(reason: String)
}

public enum HotKeyError: Error {
    case conflict(ownerTitle: String)
    case reservedBySystem
    case invalid(String)
}

// ===== PluginAPI · 输入 =====

@MainActor
public protocol InputBus {
    func subscribeToClick(_ handler: @escaping @MainActor (ClickContext) -> Void) -> Subscription
    func subscribeToPointerMove(_ handler: @escaping @MainActor (CGPoint) -> Void) -> Subscription
    func subscribeToKey(
        _ filter: KeyFilter,
        syncIntercept: (@Sendable (KeyEvent) -> KeyIntercept)?,
        handler: @escaping @MainActor (KeyEvent) -> Void
    ) -> Subscription
    /// 输入源降级通知。不参与引用计数，不产生系统资源。
    func subscribeToInterruptions(_ handler: @escaping @MainActor (InputInterruption) -> Void) -> Subscription
}

public struct InputInterruption: Sendable {
    public let source: InputSource
    public let reason: InterruptionReason
    public let recovered: Bool                  // 基座是否已自动重建成功

    public init(source: InputSource, reason: InterruptionReason, recovered: Bool)
}

public enum InputSource: Sendable, Hashable { case keyboard, pointer }

public enum InterruptionReason: Sendable, Hashable {
    case timeoutDisabled        // 系统因回调超时禁用 tap
    case permissionRevoked      // 用户在系统设置中收回授权
    case tapCreationFailed      // 创建失败，通常是权限缺失
}

public struct KeyFilter: Sendable {
    public let keyCodes: Set<Int64>
    public let requiredFlags: CGEventFlags
    public init(keyCodes: Set<Int64>, requiredFlags: CGEventFlags = [])
}

public struct KeyEvent: Sendable {
    public let keyCode: Int64
    public let flags: CGEventFlags
    public let isRepeat: Bool

    public init(keyCode: Int64, flags: CGEventFlags, isRepeat: Bool)
}

public enum KeyIntercept: Sendable { case passthrough, consume }

/// tap 线程与 Main Actor 之间唯一允许共享状态的载体。
/// 无锁、无分配，可在 syncIntercept 内安全读写。
///
/// 具体类型而非协议：tap 线程预算以微秒计，动态派发不可接受。
/// 实现要求：纯原子指令，无锁、无堆分配、无 ARC。
/// 注意 macOS 14 目标下没有 Synchronization.Atomic（15+），
/// 实现需使用 swift-atomics 或 C 原子；不得用 os_unfair_lock——它仍然是锁。
public final class AtomicFlag: @unchecked Sendable {
    public var value: Bool { get set }
    public init(_ initial: Bool = false)
}

/// 一次有效点击。基座已在 tap 侧完成时间差/位移差判定。
/// 只携带「事件时刻的标量事实」——点击会改变前台应用，事后再查得到的是新世界（§4.4.3）。
/// 对象化（NSRunningApplication）与「点击前窗口状态」都由插件在主线程自行完成。
public struct ClickContext: Sendable {
    public let location: CGPoint        // 全局屏幕坐标，与 CGEvent.location 同系
    public let timestamp: TimeInterval  // 单调时钟，仅用于排序/去重，不用于展示
    public let button: MouseButton
    public let clickCount: Int          // 1 = 单击，2 = 双击
    public let frontmostPID: pid_t?     // 点击「前」瞬间的前台进程

    public init(location: CGPoint, timestamp: TimeInterval,
                button: MouseButton, clickCount: Int, frontmostPID: pid_t?)
}

public enum MouseButton: Sendable, Hashable { case left, right, other }

public final class Subscription {
    /// 幂等；cancel 之后 handler 不再被调用。引用类型，复制句柄不影响语义。
    public func cancel()
}

// ===== PluginAPI · 快捷键 =====

public struct HotKeySpec: Hashable, Codable, Sendable {
    public let keyCode: UInt32
    public let modifiers: HotKeyModifiers      // 至少包含一个修饰键

    public init(keyCode: UInt32, modifiers: HotKeyModifiers)
}

public struct HotKeyModifiers: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32)
    public static let command: HotKeyModifiers
    public static let option: HotKeyModifiers
    public static let control: HotKeyModifiers
    public static let shift: HotKeyModifiers
}

// ===== PluginAPI · 存储与日志 =====

/// 协议而非具体类：实现（PluginStoreImpl）属于 PluginKit，PluginAPI 保持零实现。
@MainActor
public protocol PluginStore: AnyObject {
    func value<T: Codable>(_ type: T.Type, forKey: String) -> T?
    func set<T: Codable>(_ value: T, forKey: String)
    func removeAll()
}

public enum LogLevel: Sendable { case debug, info, warning, error }

/// 刻意不叫 Logger：插件一旦 import os，两个 Logger 会撞名。
@MainActor
public protocol PluginLogger {
    func log(_ level: LogLevel, _ message: @autoclosure () -> String)
    func debug(_ message: @autoclosure () -> String)
    func info(_ message: @autoclosure () -> String)
    func warning(_ message: @autoclosure () -> String)
    func error(_ message: @autoclosure () -> String)
}

// ===== PluginKit · 仅基座内部可见 =====

@MainActor
public final class PluginRegistry {
    public enum State: Equatable {
        case disabled
        case missingCapabilities(Set<Capability>)
        case active
        case failed(String)
    }
    public func register(_ types: [any FeaturePlugin.Type])
    public func setEnabled(_ id: String, enabled: Bool)
    public func state(of id: String) -> State
    public func activateAll()
    public func deactivateAll()
}

@MainActor
public final class PermissionGate {
    public func status(of capability: Capability) -> Bool
    public func isRestricted(_ capability: Capability) -> Bool
    public func refresh()
    public func request(_ capability: Capability)
    public func granted(_ set: Set<Capability>) -> Set<Capability>
    public func consumers(of capability: Capability) -> [String]
}

@MainActor
public final class HotKeyArbitrator {
    public func register(_ spec: HotKeySpec, owner: String, handler: @escaping @MainActor () -> Void) throws
    public func update(owner: String, to spec: HotKeySpec) throws
    public func unregisterAll(owner: String)
    public func availability(of spec: HotKeySpec, requester: String) -> HotKeyAvailability
    public func ownerDescription(of spec: HotKeySpec) -> String?
}

@MainActor
public final class TaskRunner {
    public func perform<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T
}
```

## 附录 B · 决策记录（ADR）

| 编号 | 决策 | 结论 | 核心理由 |
|---|---|---|---|
| ADR-1 | 插件进程模型 | in-process | 权限不可转授；进程外必致多次授权，破坏"一次安装一次授权"（§3.1） |
| ADR-2 | 插件加载方式 | 静态链接 SwiftPM module | 内部插件无热更新需求；静态链接不触发 Library Validation，安全基线不降（§3.4） |
| ADR-3 | 插件语言 | Swift | 业务主体是高频系统 API 调用；脚本层需海量桥接，且在输入回调路径上必然超出延迟预算 |
| ADR-4 | 事件源归属 | 基座独占 + 引用计数按需创建 | tap 数量必须与插件数解耦（§3.2）；零订阅即零 tap，兑现空载承诺（§1.1） |
| ADR-5 | 鼠标 tap 模式 | `.listenOnly` | 绝不介入系统原生交互语义 |
| ADR-6 | 指针移动实现 | `NSEvent` 全局监听 + 节流 | 移动事件频率过高，进入 Event Tap 会拖慢全系统输入 |
| ADR-7 | 键盘回调结构 | 三段式（预筛 / 同步拦截 / 主线程业务） | 需要吞键的功能必须同步决策，但有状态业务不能跑在 tap 线程（§6.3） |
| ADR-8 | 快捷键注册 | 基座仲裁，冲突抛错 | 全局快捷键是同一命名空间，静默覆盖会让用户误判功能损坏（§6.4） |
| ADR-9 | 插件默认状态 | 全部默认关闭 | 与权限最小化一致：未启用前不申请权限、不订阅事件（P2） |
| ADR-10 | 插件版本约束 | 仅构建期校验 `minHostVersion`，不启用 library evolution | 插件与基座永远同版本发版，不存在二进制错配（§6.7） |
| ADR-11 | 配置存储 | 每插件独立 UserDefaults suite | 新增插件不修改基座任何配置结构（§6.5） |
| ADR-12 | 历史配置迁移 | 不做 | 全新独立项目，无历史基线，明确裁剪（§1.3） |
| ADR-13 | 插件卸载 | 不提供，只提供"重置配置" | 静态链接代码无法移除，诚实呈现能力边界（§6.6） |
| ADR-14 | 基座功能范围 | 零业务功能，但必含应用壳层与权限页 | 壳层是应用身份，权限页是唯一的授权入口；两者都不产生业务行为（P1、§1.1） |
| ADR-15 | 系统 API 归属 | **零封装**。基座不提供 `minimize` / `activate` / `captureWindowImage` / `openSystemSettings` 等任何语义方法，插件直接调系统 API | 避免基座接口随插件需求无限膨胀；能强制的是执行上下文（`performBackground`），不是能力（§4.4） |
| ADR-16 | 三类必要例外 | 全局资源（输入/快捷键/通知）、全局副作用（权限申请）、事件时刻事实（点击前前台应用）仍由基座中介 | 三者本质是"资源唯一性"与"信息不可重建"，不是"能力封装"（§4.4.2、§4.4.3） |
| ADR-17 | 权限探测与申请 | 探测可下放（插件可自行 `AXIsProcessTrusted`），申请必须收敛 | 探测幂等无副作用；申请会弹系统框，多插件并发申请会让用户无法归因（§4.4.6） |
| ADR-18 | 快捷键自定义 | 插件自定义组合键，基座仲裁并持久化于插件侧 | 冲突必须在注册时暴露而非静默覆盖；基座不持有插件配置（§6.4） |
| ADR-19 | 安全防护的表述 | 如实标注每条约束的真实强度，区分"编译期强制"与"约定" | 零封装使大部分防护退化为约定；错误的安全感比没有防护更危险（§9.2） |
| ADR-20 | 应用身份来源 | 全部读 Bundle，代码中不出现字面量 | 名称/图标/版本是发布配置而非源码内容，写死必然漏改（§6.9） |
| ADR-21 | 设置页归属 | `PluginManifest` 只放静态元信息，设置页是 `FeaturePlugin` 的实例方法 `makeSettingsView()` | 静态闭包拿不到实例状态，切换页面即丢失未保存编辑；列表渲染仍不需要实例化（§5.1、§6.6） |
| ADR-22 | 点击快照的内容 | 只携带标量 + `frontmostPID`，不携带 `NSRunningApplication` | `Sendable` 约束与 tap 线程「不碰 AppKit」同时排除对象；对象化下沉到插件主线程（§4.4.3、§7） |
| ADR-23 | 能力与基础设施的表述 | 五项能力（输入/权限/快捷键/通知/performBackground）+ 两项基础设施（store/logger） | 避免把无全局语义的本地设施混进门控体系（§5.5） |
| ADR-24 | 输入降级事件的入口 | `InputBus.subscribeToInterruptions`，不参与引用计数 | 文档要求插件"处理 tap 中断"却无订阅入口，等于要求一件做不到的事（§6.3） |
| ADR-25 | 权限映射粒度 | 按订阅类型分别映射（键盘→输入监控；点击/指针→辅助功能） | 笼统写"输入总线需要输入监控"会让插件声明错能力，用户跑到错误的系统设置页（§5.4） |
| ADR-26 | 后台执行上下文命名 | `performBackground`（原 `performAX`） | 名字里带 AX 会让插件作者以为截图/窗口枚举不归它管，转而自建队列，绕过唯一的串行执行器（§5.3） |
