# 插件市场与自动更新 · 设计

> 状态：**已实现**（索引协议 / 客户端 / 更新中心 / 市场页 / 发布脚本 / 校验工具）
> 相关文档：`External-Plugin-Design.md`（包格式与逐插件授权）

---

## 1. 目标与非目标

**目标**

1. 用户能在基座内浏览、安装、更新插件，不需要手动找包、拖文件。
2. 更新不破坏既有授权：常规升级保留启用状态与逐插件授权；只有**能力声明变化**才要求重新确认。
3. 市场不可信：索引与包都要校验；市场只提供元数据，不参与信任判定。
4. 支持自建市场：地址与公钥都可配置，不写死某一个域名。

**非目标**

- 不做应用内购买/计费、不做评分评论。
- 不做增量（差分）更新与灰度发布。
- 不做自动回滚（升级失败由用户重装上一版本）。
- 不做插件自动上架审核流水线（发布脚本只负责生成索引与签名）。

---

## 2. 信任模型

```
用户/开发者
   │ 私钥签名
   ▼
 index.json（信封：payload + signature）        ← 基座用内置公钥校验 Ed25519
   │ downloadURL + sha256
   ▼
 plugin.zip ──sha256──► 校验一致
   │
   ▼
 PluginInstaller.inspect（结构 / 代码签名 / Team / 版本 / ID）
   │
   ▼
 安装 → 逐插件授权（consent）→ 加载
```

三条硬规则：

1. **签名只覆盖索引**。索引里声明了包的 sha256，因此索引可信 ⇒ 能锁定具体包。
2. **市场不是信任根**。即使索引被合法签名，包仍要过完整的安装校验（代码签名、Team 白名单、`apiVersion`、`minHostVersion`）。
3. **公钥来自基座**（Info.plist 的 `ChassisMarketplacePublicKey`），不来自网络。换市场 = 换公钥。

开发便利：`DEBUG` 构建允许**本地来源**（`file://` / `localhost`）的未签名索引；Release 一律要求签名，避免「忘了签名」成为默认行为。

---

## 3. 索引格式

`index.json`（推荐签名信封）：

```json
{
  "payload": "{...索引 JSON 原文...}",
  "signature": "<Ed25519(payload).base64>"
}
```

`payload` 解析后：

```json
{
  "schema": 1,
  "generatedAt": "2026-10-29T14:10:18Z",
  "plugins": [
    {
      "id": "com.example.chassis.hello",
      "name": "示例外部插件",
      "summary": "演示外部插件包",
      "version": "1.0.0",
      "minHostVersion": "1.0.0",
      "apiVersion": 1,
      "downloadURL": "https://example.com/plugins/com.example.chassis.hello-1.0.0.zip",
      "sha256": "bb4f7bf7…",
      "size": 123456,
      "vendor": "Chassis Samples",
      "requiredCapabilities": [],
      "optionalCapabilities": ["screenCapture"]
    }
  ]
}
```

约定：

- `signature` 覆盖 **payload 原始字节**，不做 JSON 规范化，避免两端序列化差异导致「签名对了但校验失败」。
- `minHostVersion` / `apiVersion` 由基座二次校验，索引里的值只是提示。
- 同一 `id` 只保留最新版本；历史版本不进入索引。

---

## 4. 更新检测

```
刷新索引 → 对每个 plugin：
  minHostVersion > 当前基座  → incompatible（不可安装）
  未安装                     → notInstalled
  已安装且 installed >= 索引 → installed
  已安装且 installed <  索引 → updateAvailable(installedVersion)
```

版本比较复用安装器里的 `SemanticVersion`（按数字段逐段比较，预发布标记视为同版本）。

排序：可更新 → 可安装 → 进行中 → 失败 → 已安装 → 不兼容，同级按名称。

---

## 5. 自动更新

| 项 | 取值 |
|---|---|
| 自动检查 | 默认开启；启动 5 秒后首次检查，之后每 6 小时一次 |
| 自动安装 | 默认**关闭**（更新可能改变能力声明） |
| 手动检查 | 市场页「检查更新」；60 秒内不重复请求 |
| 并发 | 安装串行执行，避免同时解压/替换 |

自动安装的边界：

- 只处理 `updateAvailable`，不会顺带安装未安装的插件。
- 更新后若能力声明变化，`PluginConsentStore` 的清单指纹不匹配 → 插件回到 `missingCapabilities`，UI 提示重新授权；日志记录「更新改变了能力声明」。
- 更新不改变启用状态：`PluginStore` 按插件 ID 隔离，配置天然保留。

---

## 6. 安装流程（复用外部插件链路）

```
MarketplaceClient.download  → 临时目录 zip（校验 sha256）
PluginInstaller.inspect     → 结构/签名/Team/版本校验（policy 与手动安装完全一致）
断言 staged.id == index.id  → 防止索引挂羊头卖狗肉
PluginInstaller.install     → 复制到 Application Support/Plugins/
onInstalled → registry.registerExternal(...)  → 插件列表/Dock 立即出现
```

任何一个环节失败都不会改动已安装内容；失败原因写进市场页对应行与日志。

---

## 7. 配置

| 来源 | 键 | 说明 |
|---|---|---|
| Info.plist | `ChassisMarketplaceURL` | 打包时注入的索引地址 |
| Info.plist | `ChassisMarketplacePublicKey` | Ed25519 公钥（base64） |
| UserDefaults | `host.marketplaceURL` | 覆盖上面两项，便于自建/联调 |
| UserDefaults | `host.marketplacePublicKey` | 同上 |
| UserDefaults | `host.autoCheckPluginUpdates` | 默认 true |
| UserDefaults | `host.autoInstallPluginUpdates` | 默认 false |

本地联调：

```bash
defaults write com.gaelthas.chassis host.marketplaceURL "file:///…/Chassis-Plugins/Market/index.json"
defaults write com.gaelthas.chassis host.marketplacePublicKey "viVbaAgf…="   # 需与签名私钥配对
```

---

## 8. 发布流程（插件仓库）

```bash
# 一次性：生成签名密钥（私钥不要入库，.gitignore 已忽略）
cd Chassis-Plugins/Market && swift make-index.swift --generate-key .market-key
# 输出公钥 → 写入基座 Info.plist 的 ChassisMarketplacePublicKey

# 每次发布
./Chassis-Plugins/Examples/build-hello.sh    # 产出 dist/*.chassisplugin
bash Chassis-Plugins/Market/build-market.sh  # zip + sha256 + 签名 → Market/index.json、Market/packages/
```

产物：`Market/packages/<id>-<version>.zip` 与签名后的 `Market/index.json`，整体上传到静态托管即可（无需服务端）。

---

## 9. 验收

| 编号 | 判据 | 结果 |
|---|---|---|
| M1 | 未签名索引 + 本地来源：能列出插件并安装 | ✅ `MarketCheck` |
| M2 | 签名索引 + 正确公钥：全链路通过 | ✅ |
| M3 | 篡改 payload：`索引签名校验失败`，不进入安装流程 | ✅ 负向验证 |
| M4 | 篡改 zip：`插件包校验和不匹配，已放弃安装` | ✅ 负向验证 |
| M5 | 高版本索引：状态变为 `updateAvailable(installedVersion: "1.0.0")` | ✅ |
| M6 | 安装后启用 → `active`，设置页可用；停用/卸载后清理干净 | ✅ |
| M7 | 索引 ID 与包内 ID 不一致时拒绝安装 | 代码断言（`staged.manifest.id == plugin.id`），未构造用例 |

---

## 10. 未实现 / 后续

- 增量更新、灰度发布、自动回滚。
- 应用自身的自动更新（当前只覆盖插件；`ChassisUpdateURL` 仍是占位）。
- 索引缓存与 ETag / 条件请求（目前每次全量拉取，索引很小）。
- 市场侧的权限说明文案（目前复用插件清单里的能力枚举）。

---

## 12. 多市场与增量发布（v2）

### 12.1 多来源

- 官方来源来自 Info.plist（`ChassisMarketplaceURL` / `ChassisMarketplacePublicKey`），用户不可删除，可停用。
- 第三方来源由用户在「添加市场…」中录入：名称 + 索引地址 + 该市场的签名公钥。
- 合并规则：按来源顺序取第一个出现的插件 ID（官方优先），后出现的同名插件忽略；
  每个来源独立验签，任一来源失败不影响其它来源，失败原因汇总展示。
- 存储：`host.marketplaceSources`（JSON 数组）。旧版 `host.marketplaceURL` / `host.marketplacePublicKey`
  会自动迁移成「自定义市场」来源，不会丢配置。

### 12.2 增量发布

`Chassis-Plugins` 的发布单位是「插件」而不是「Release」：

```
Manifests/<id>.json        版本号 = 该插件当前版本（发布脚本可自动 +1）
Market/packages/<id>-<版本>.zip
Market/index.json          所有插件的最新版本清单（签名）
```

`Scripts/publish.sh --bump patch SlowQuit` 会：升 `SlowQuit` 的版本 → 只重建它的包 →
写入新的 zip（旧版本 zip 保留，便于回滚）→ 重建并签名 `index.json`。

因此「这次只更新了一个插件」是完全正常的：索引里只有它的 `version/sha256/downloadURL` 变了，
其余条目指向上一版包文件，基座按 `installedVersion < indexVersion` 判定更新。

### 12.3 托管

默认用 `raw.githubusercontent.com/gaelthas/Chassis-Plugins/main/Market/...`，零运维；
也可以改 `MARKET_BASE_URL` 指向 GitHub Pages / 对象存储 / CDN。
注意：raw 有几分钟缓存，且仓库必须是公开的（私有仓库需要 token，当前客户端不支持）。
