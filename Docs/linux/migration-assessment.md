# Linux 迁移评估报告与技术路线

> 状态：**待确认**。本文件是 AGENTS.md 第 1 条要求的评估产出，确认后才进入实现。
> 基线：上游 `qunqin24/Pulse` @ `8eac7d9`（v1.3.1），本仓库 `dev` 分支。
> 实测环境：Deepin 25 / x86_64 / glibc 2.38 / Swift 6.4 / X11 会话。
> 标注 **【实测】** 的结论来自本机编译或运行结果；标注 **【读码】** 的来自通读源码；标注 **【待验】** 的是尚未验证、不得当作结论使用的事项。

---

## 1. 结论摘要

### 1.1 路线：保留 Swift 核心，UI 另起进程

**推荐：Swift 核心层（Providers + Readers + Auth + Usage）继续用 Swift，编译成无 GUI 的 `pulse` 可执行文件 + 常驻守护进程；悬浮窗 UI 作为独立进程，用 GTK4 + `gtk4-layer-shell` 实现，通过既有 `pulse --json` 契约 + 一条本地 IPC 通道拿数据。**

理由按重要性排序：

1. **上游血缘是这个项目最大的单项资产。** 20 个 Provider 的取数逻辑高度依赖各家未公开的账号端点，上游会持续跟着对方 API 变化修。只要核心层保持 Swift 单目标，`git merge upstream/main` 就能无限期继承这些修复。一旦把 Providers 翻译成别的语言，这条线永久断掉，等于接手 20 个会腐烂的爬虫。
2. **Providers/Readers 的代码本来就是为跨平台写的。** 实测：86 个文件（Providers 30 + Readers 56）里 82 个只依赖 `Foundation`/`SQLite3`；`DatabaseReaderSupport` 已经内建了 `xdgDataHome` / `localAppData` / `appData` 三个平台路径助手，并且把 `home` 和 `environment` 作为参数注入——它本来就在读 Windows/macOS/Linux 三种 agent 存放位置。这部分几乎不用重写。
3. **UI 层占的比重大但价值密度低。** 实测 31 个 Panel 文件里 25 个绑定 Apple 专属模块，0 个可移植。这部分是纯粹的呈现逻辑，重写不丢任何领域知识。
4. **`--json` 契约已经存在且被上游当作稳定 API 维护**（`Docs/json-output.md` 明确说"重命名字段会破坏别人的状态栏"）。把它升级成核心与 UI 之间的进程边界，是顺着现有设计走，不是新发明。
5. **无 GUI 的 CI 才可能。** 核心层能在没有 DISPLAY/WAYLAND_DISPLAY 的环境里 `swift test` 全绿，这是阶段一唯一可靠的验收手段。

**不推荐整体换语言重写**：那意味着 20 个 Provider × 平均 290 行 + 56 个 Reader × 平均 187 行的行为等价性证明，且此后永久失去上游同步能力。工作量是方案 A 的 3～5 倍，风险不在"写不出来"，而在"写得不一样且没人发现"。

**不推荐 Swift 单进程直连 GTK4**：Swift 调 GTK4 的 C API 理论上可行（Swift C 互操作很强），但 GObject 信号需要手写 trampoline，且业界零先例、无可参考的维护经验。作为备选保留（见 §6.3）。

### 1.2 三个必须先接受的现实

| 现实 | 影响 |
|---|---|
| **GNOME Wayland 下无法做到贴边常驻悬浮窗** | `zwlr_layer_shell_v1` 是 Wayland 上唯一正确的"贴边 + 置顶 + 不抢焦点"协议，GNOME/Mutter **不实现**它。GNOME Wayland 用户只能退化为普通置顶窗口（会被某些全屏场景遮挡、位置由合成器摆布）。这是协议层限制，不是实现问题。【读码 + 协议常识，需在真实 GNOME 上复现后写入 README】 |
| **`pulse --json` 只读缓存、绝不取数** | 【读码】`UsageReport.run()` 读的是 `UsageCache` 里 App 上次落盘的结果。所以 AGENTS.md 里"跑通 Claude Code / Codex 的 `pulse --json`"这条验收，**必须先有一个无 GUI 的取数入口**。现状没有。需要新增 `pulse --refresh`（对 macOS 是纯增量，不改变现有行为）。 |
| **全库当前零条件编译** | 【实测】`#if canImport` / `#if os(` 在 `Sources/` + `Tests/` 中出现 **0 次**。首次 typecheck 在第一个 `import CryptoKit` 处即中止，一个文件都编译不过。阶段一是从零搭脚手架。 |

---

## 2. 实测基线

### 2.1 代码规模

| 目录 | 文件数 | 行数 | 仅依赖可移植模块 | 需改造 |
|---|---:|---:|---:|---:|
| `Providers/` | 30 | 8,723 | **28** | 2 |
| `Usage/Readers/` | 56 | 10,462 | **54** | 2 |
| `Usage/`（本级） | 32 | 9,576 | 28 | 4 |
| `Panel/` + `Panel/BotMark/` | 31 | 9,311 | 6 | **25** |
| `Settings/` | 14 | 5,802 | 2 | **12** |
| `App/` | 12 | 3,015 | 3 | **9** |
| `Auth/` | 10 | 2,958 | 4 | 6 |
| **Sources 合计** | **185** | **49,847** | **125** | **60** |
| `Tests/PulseTests/` | 70 | 19,483 | 61 | 9 |
| **总计** | **255** | **69,330** | **186 (73%)** | **69** |

"可移植"= 只 `import Foundation` / `Observation` / `SQLite3` / `Darwin`。

### 2.2 模块可用性（Swift 6.4 on Deepin 25，逐条 `swiftc -typecheck` 实测）

| 模块 | 状态 | 用到它的文件数 | 替代方案 |
|---|---|---:|---|
| `Foundation` | ✅ | 150 | — |
| `FoundationNetworking` | ✅ | — | `URLSession` 在 Linux 需**显式** `import FoundationNetworking` |
| `Observation` | ✅ | 6 | — |
| `Testing`（swift-testing） | ✅ | 70（测试） | 工具链自带 |
| `SQLite3` | ⚠️ 装 `libsqlite3-dev` 后可用 | 9 | 工具链**不提供** modulemap，须自建 `systemLibrary` target |
| `Darwin` | ⚠️ 语义近似 | 1 | `Glibc`；`autoreleasepool` 需条件编译（16 处） |
| `CryptoKit` | ❌ | 10 | **swift-crypto** 提供同名 `Crypto` 模块（AES-GCM / SHA256 / SymmetricKey 全覆盖） |
| `CommonCrypto` | ❌ | 1 | 同上 |
| `AppKit` / `SwiftUI` | ❌ | 22 / 36 | GTK4 重写 |
| `CoreGraphics` | ❌ | 6 | cairo（GTK4 自带） |
| `Network`（`NWConnection`） | ❌ | 3 | POSIX socket / `NIO` |
| `os`（`Logger`） | ❌ | 2 | `swift-log` 或 stderr |
| `IOKit` | ❌ | 2 | `/etc/machine-id`、`/sys/class/dmi/id/product_uuid` |
| `Security`（Keychain） | ❌ | 1 | libsecret / Secret Service；降级 0600 文件 |
| `ServiceManagement` | ❌ | 1 | XDG autostart `.desktop` |
| `Carbon`（`RegisterEventHotKey`） | ❌ | 1 | X11 `XGrabKey`；Wayland 走托盘降级 |
| `UserNotifications` | ❌ | 2 | `libnotify` / D-Bus `org.freedesktop.Notifications` |
| `Sparkle` | ❌ | 1 | 移除；改 GitHub Release 手动更新 |

### 2.3 Foundation 行为差异（实测）

| 事项 | macOS | Linux |
|---|---|---|
| `FileManager.url(for:.applicationSupportDirectory,…)` | `~/Library/Application Support` | `~/.local/share`（尊重 `XDG_DATA_HOME`）✅ |
| `URL.applicationSupportDirectory`（静态属性） | 存在 | **不存在，编译期报错** ❌ — 3 处用到，须改写 |
| `URL.cachesDirectory`（静态属性） | 存在 | **不存在** ❌ |
| `UserDefaults` | 持久化，域 = bundle id | 可用 ✅，落盘 `~/.config/<进程名>.plist`，域 = 进程名 |
| `JSONEncoder` + `.iso8601` | ✅ | ✅ |
| actor / `TaskGroup` / `DispatchSemaphore` | ✅ | ✅ |

> `UserDefaults` 在 Linux 上域恒等于进程名，所以 `LegacyDefaults` 维护的"bundle 域 vs `swift run` 域"双域机制在 Linux 上自然坍缩为单域——这是简化，不是问题，但迁移旧配置时要注意 macOS 的 `Pulse` 域和 bundle 域不能都想当然地映射过来。

### 2.4 macOS 专属 API 清单（源码计数）

| API / 机制 | 命中文件数 | 集中位置 |
|---|---:|---|
| `NSWorkspace` | 17 | `Auth/OAuthLogin`、`Auth/CursorWebLogin`、`Auth/BrowserCookies`、`Usage/UsageStore`、`Settings/*` |
| `NSEvent` | 24 | `Panel/*`、`Settings/ShortcutField` |
| `NSMenu` / `NSStatusItem` | 13 / 2 | `App/AppDelegate` |
| `NSScreen` | 11 | `Panel/FloatingPanelController`、`Panel/PanelScreen`、`Panel/ActiveDisplayFollower` |
| `NSImage` / `NSColor` / `NSPasteboard` / `NSAlert` / `NSOpenPanel` | 7/4/6/2/1 | `Panel/*`、`Settings/*` |
| `autoreleasepool` | 16 | 分散；`#if canImport(ObjectiveC)` 包裹即可 |
| `@objc` / `#selector` | 3 / 3 | `App/AppDelegate`、`App/GlobalShortcut` |
| `UserDefaults` | 74 | `Settings/AppSettings`（1380 行）为核心 |
| `SecItem`/`kSec*` | 1（8 处调用） | `Auth/BrowserCookies`（浏览器 cookie 解密密钥） |
| `SMAppService` | 5 | `App/LoginItem` |
| `SPU*`（Sparkle） | 7 | `App/AppUpdate`、`Settings/SettingsView` |
| `RegisterEventHotKey` | 3 | `App/GlobalShortcut` |
| `NWConnection` | 3 | `Auth/LoopbackCallback`（OAuth 回环回调） |
| `UNUserNotification*` | 9 | `Usage/UsageAlerts`、`Settings/SettingsView` |
| `IOServiceGetMatchingService` | 2 | `Auth/LocalSecrets`、`Auth/APIKeyStore` |

**关键发现**：`WKWebView` 与 `ASWebAuthenticationSession` 命中 **0 次**。OAuth 走的是系统浏览器 + `pulse://` URL scheme 回跳 + 本地回环端口，不是内嵌 WebView。这意味着登录流程的 Linux 移植比预期简单——只有回环 socket 和 URL scheme 注册两块要替。

---

## 3. 逐模块评估

标注含义：**A 可直接移植**（加 `import` 条件即可编译）／**B 需条件编译改造**（逻辑保留，接口要换）／**C 必须重写**（macOS 呈现层，无对应物）。

### 3.1 `Providers/`（30 文件，8,723 行）— **A 为主，2 个文件为 B**

| 文件 | 档 | 说明 |
|---|---|---|
| 28 个 `*UsageService.swift` | **A** | 只 `import Foundation`，HTTP + JSON 解析，`URLSession` 加 `FoundationNetworking` 即可 |
| `VolcengineSigner.swift` | **A**【实测：单测已存在且纯 Foundation】 | 自实现签名，无平台依赖 |
| 依赖 `CryptoKit` 的 2 个 | **B** | 换成 swift-crypto 的 `Crypto` 模块，API 同名 |
| 依赖 `SQLite3` 的 1 个 | **B** | 需 `systemLibrary` target（见 §5 P1.1） |

**这一层是纯赚的。** 唯一注意：`ProviderAccess` 里的路径描述文案提到 macOS 专属路径（Keychain、`Claude.app`），Linux 下要换文案。

### 3.2 `Usage/Readers/`（56 文件，10,462 行）— **A 为主，少量 B**

【读码】`DatabaseReaderSupport` 已经把 `home: URL` 和 `environment: [String:String]` 作为参数，并内建：
- `xdgDataHome(home:environment:)` → `$XDG_DATA_HOME` else `~/.local/share`
- `localAppData(environment:)` → `%LOCALAPPDATA%`
- `appData(environment:)` → `%APPDATA%`
- `applicationSupport(home:)` → 硬编码 `Library/Application Support`

需要做的**只有一件事**：给 `applicationSupport` 加平台分支，返回 `~/.config`（Linux）。这是**加候选路径**，不是改逻辑。

Reader 读的目标是别的 agent 的存放位置，其中 `~/.claude`、`~/.codex`、`~/.grok`、`~/.commandcode`、`~/.config/*` 在 Linux 上确实存在。**`Library/Application Support/*` 系列（Cursor `state.vscdb`、CherryStudio、kiro-cli、Copilot 日志、Goose、Zed、Micode）在 Linux 上要换成 `~/.config/*`**，需要按 agent 逐个核对真实路径（Linux 版 Cursor 用 `~/.config/Cursor/User/globalStorage/state.vscdb`）。

档位：**A**（纯路径候选扩展）。风险是"路径写错导致静默读不到数据"，所以阶段一必须用真实样本数据做回归——正好对应 AGENTS.md 的验收条目。

### 3.3 `Usage/`（本级，32 文件，9,576 行）— **A 为主，4 个 B**

| 文件 | 档 | 说明 |
|---|---|---|
| `UsageReport.swift` | **A**【读码：只 `import Foundation`】 | **这是阶段一的验收入口** |
| `UsageCache` / `UsageLedger` / `AgentActivity` / `ModelPrices` / `UsageForecast` | **A** | 纯 Foundation + actor |
| `UsageStore.swift` | **B** | 混入 `NSWorkspace`（打开设置页）；抽出动作接口即可 |
| `UsageAlerts.swift` | **B** | `UNUserNotificationCenter` → `libnotify`/D-Bus |
| `PulseStorage`（定义在 `ModelPrices.swift`） | **B** | 改用 `FileManager.url(for:)`，Linux 落 `~/.local/share/Pulse` |
| `AgentSQLite.swift` 等 `SQLite3` 使用者 | **B** | modulemap |

### 3.4 `Auth/`（10 文件，2,958 行）— **B/C 各半**

| 文件 | 行 | 档 | Linux 替代 |
|---|---:|---|---|
| `OAuthLogin.swift` | 765 | **B** | 逻辑（PKCE、token 交换、刷新）可留；`NSWorkspace.open` 换成 `xdg-open`；`pulse://` scheme 注册换成 `.desktop` 的 `MimeType=x-scheme-handler/pulse` |
| `ChromiumLocalStorage.swift` | 686 | **A/B** | 自有格式解析，纯 Foundation + SQLite3 → **A**；但需补 Linux 浏览器路径表 |
| `BrowserCookies.swift` | 482 | **B** | Chromium cookie 解密：`SecItem` 取密钥 → Linux 从 `~/.config/<browser>/Local State` 读 `os_crypt.encrypted_key`，DPAPI 那层在 Linux 上不存在（密钥就是 `v10`/`v11` 前缀 + 固定 key，或 GNOME keyring 里的 "Chrome Safe Storage"）。**须实测各浏览器行为差异** |
| `LoopbackCallback.swift` | 259 | **B**【读码：`NWConnection` 仅 3 处】 | 换成 `socket()`/`accept` 或 NIO。逻辑简单，风险低 |
| `GitHubDeviceLogin.swift` | 198 | **A** | 纯 HTTP + 轮询 |
| `CursorAppLogin.swift` / `CursorWebLogin.swift` | 171/155 | **B** | 同上 cookie/密钥问题 |
| `AccountCredentials.swift` / `APIKeyStore.swift` | 99/71 | **B** | `keys.dat`/`accounts.dat` 加解密：`LocalSecrets` 用 IOKit `IOPlatformUUID` + `SHA256(purpose ‖ uuid)` 派生 AES-GCM 密钥 → Linux 用 `/etc/machine-id`（或 `/sys/class/dmi/id/product_uuid`）；AES-GCM 换 swift-crypto。**加密逻辑可原样保留，只换熵源** |
| `LocalSecrets.swift` | 72 | **B** | 同上 |

**注意**：`LocalSecrets` 的密钥绑定本机，所以 macOS 上的 `keys.dat` 拷到 Linux **解不开**。跨平台迁移配置时 API key 必须重填——这是设计上的安全特性，不是 bug，但 README 要写清楚。

### 3.5 `App/`（12 文件，3,015 行）— **B/C**

| 文件 | 行 | 档 | 说明 |
|---|---:|---|---|
| `AppSettings.swift` | 1,380 | **B** | `@Observable` + `UserDefaults`，Linux 可用；须审 74 处 `UserDefaults` 的类型语义与 `LegacyDefaults` 双域机制 |
| `StatusLineHook.swift` | 295 | **B** | 写 Claude Code `settings.json` 的逻辑可留；可执行路径解析要改 |
| `GlobalShortcut.swift` | 280 | **C** | `RegisterEventHotKey` → X11 `XGrabKey`（独立线程 + `XNextEvent`）；**Wayland 无统一协议** → 降级托盘菜单 |
| `AppDelegate.swift` | 274 | **C** | `NSApplicationDelegate` 全套 → GTK4 `GtkApplication` 生命周期 |
| `Localization.swift` | 174 | **B** | `String.localized` 现读 `*.lproj`；Linux 改用 gettext `.mo` 或自建查表（保留 5 语言） |
| `NetworkProxy.swift` | 151 | **B** | `URLSessionConfiguration` 代理设置 ✅；"作用于 helper 进程"那部分要重做 |
| `LoginItem.swift` | 144 | **C** | `SMAppService` → `~/.config/autostart/pulse.desktop` |
| `AppUpdate.swift` | 125 | **C** | Sparkle → 整体移除，改 GitHub Release 检查 |
| `PulseApp.swift` | 67 | **C** | `@main` SwiftUI App → Linux 下换纯 CLI `main` |
| `ProviderSelection.swift` | 44 | **A** | 纯逻辑 |
| `PulseLink.swift` | 41 | **A** | URL 解析，纯 Foundation |
| `LegacyDefaults.swift` | 40 | **B** | Linux 单域，逻辑简化 |

### 3.6 `Panel/`（31 文件，9,311 行）— **C，全部重写**

| 子系统 | 文件 | 重写要点 |
|---|---|---|
| 窗口与放置 | `FloatingPanelController`、`PanelScreen`、`ActiveDisplayFollower`、`PanelPlacement`、`PanelMetrics` | `NSPanel` + `NSScreen` → GTK4 `GtkWindow` + `gdk_monitor_*`；Wayland 走 `gtk4-layer-shell`（`LAYER_TOP` + `ANCHOR_*` + `set_exclusive_zone`）；X11 走 `override-redirect` + `_NET_WM_STATE_ABOVE` |
| 圆环绘制 | `UsageRingView`、`PanelSurface`、`NotchBerthShape`、`NotchAlertShape`、`UsageBubbleShape` | SwiftUI `Shape` → GTK4 `GtkDrawingArea` + cairo（圆弧、渐变、模糊背景） |
| 详情卡片 | `UsageDetailCard`、`AccountUsageCard`、`UsageDockView`、`FloatingUsagePanelView` | SwiftUI 视图树 → GTK4 widget 树 |
| 输入 | `PanelPointerWatcher`、`PointerEntryReporter` | 上游文档明确记着"`.onHover` 在非 key 面板上不работ、进入靠 tracking area、离开靠轮询指针"。GTK 用 `GtkEventControllerMotion` 的 `enter`/`motion` + 定时轮询 `gdk_device_get_position` 判断离开 |
| 配色 | `UsageTint`、`BotMarkTint` | 【读码】纯阈值逻辑（`pulseGood`/`pulseCaution`/`pulseWarning`/`pulseExhausted`），**可原样移植成纯函数** → 档 **A**，虽有 6 个测试文件依赖它 |
| BotMark 动画 | 15 个文件 | SwiftUI 粒子动画 → cairo 逐帧；**建议阶段二末尾做，或首版直接砍掉**（见 §8） |

> `Panel/` 里 `UsageTint`、`BotMarkTint`、`BotMarkConfig`、`BotMarkProgramme` 等 6 个文件实测是"仅依赖可移植模块"的纯逻辑（它们是颜色和动画参数计算）。重写 UI 时**这部分逻辑要保留、只换绘制后端**。

### 3.7 `Tests/`（70 文件，19,483 行）— **A 为主**

【实测】70 个文件里 61 个只依赖 `Foundation`/`Testing`/`SQLite3`。

- **A（61 个）**：Linux 上应直接全绿。这是阶段一最好的回归网。
- **B/C（9 个）**：`UsageTintTests`、`GlobalShortcutTests`、`BotMarkChoreographyTests`、`MenuBarIconSettingTests`、`BotMarkTests`、`ProviderMarkTests`、`RailMoneyTests` 等。用 `#if canImport(AppKit)` 排除，或改写为对纯逻辑部分的测试。

`Tests/PulseTests/Fixtures/` 是捕获的真实 provider 响应，**跨平台可直接复用**，是 provider 行为等价性的现成证据。

---

## 4. macOS → Linux 替代对照表

| macOS 机制 | 现状位置 | Linux 替代 | 档 | 实测状态 |
|---|---|---|---|---|
| Keychain（`SecItem`） | `BrowserCookies`（取浏览器解密密钥） | Secret Service（`libsecret`/`secret-tool`）；无服务时降级 0600 文件 | B | 【待验】Linux 上 Chrome 系 `v10` 前缀的密钥来源需实测 |
| `LocalSecrets`（IOKit `IOPlatformUUID` 派生密钥） | `LocalSecrets`、`APIKeyStore` | `/etc/machine-id` 或 `/sys/class/dmi/id/product_uuid`；加密算法不变（swift-crypto AES-GCM） | B | 【待验】`product_uuid` 普通用户是否可读 |
| `SMAppService` | `LoginItem` | `~/.config/autostart/pulse.desktop` + `X-GNOME-Autostart-enabled` | C | 标准 XDG，低风险 |
| Sparkle | `AppUpdate`、`SettingsView` | 整体移除；`--check-update` 查 GitHub Release | C | — |
| `NSPanel` 悬浮窗 | `Panel/` | GTK4 + `gtk4-layer-shell`（Wayland）／`override-redirect` + `_NET_WM_STATE_ABOVE`（X11） | C | 【待验】GNOME Wayland 不支持 layer-shell |
| `NSScreen` 多显示器 | `FloatingPanelController`、`ActiveDisplayFollower` | `GdkDisplay` + `gdk_monitor_get_geometry`；X11 下可读 `_NET_WORKAREA` | C | GDK 两后端都有等价 API |
| `RegisterEventHotKey` | `GlobalShortcut` | X11：`XGrabKey` + 独立事件线程；Wayland：**无统一协议** → 托盘菜单 + 可选读 compositor 配置 | C | 【实测：当前会话 X11】Wayland 需另测 |
| Chromium cookie 读取 | `BrowserCookies`、`ChromiumLocalStorage` | 路径：`~/.config/google-chrome`、`~/.config/chromium`、`~/.config/BraveSoftware/Brave-Browser`、`~/.config/microsoft-edge` | B | 【待验】Chrome 127+ `app_bound_encryption` 在 Linux 的差异 |
| `*.lproj` 本地化 | `Resources/{en,ja,ko,zh-Hans,zh-Hant}.lproj`、`Localization.swift` | gettext `.mo` 或自建 hashmap；**保留 5 语言，保留 `Scripts/check-localization.sh` 的键校验** | B | — |
| `codesign` / `xattr` / `dmg` | `Scripts/bundle.sh`、`Scripts/dmg.sh` | 不需要；产出裸可执行文件 + `.desktop` + `.deb`/AppImage | C | — |
| `NSWorkspace.open` | 6 文件 17 处 | `xdg-open`（`GAppInfo` 或 `gio open`） | B | — |
| `NWConnection` 回环回调 | `LoopbackCallback` | `socket()`/`bind`/`accept` 或 SwiftNIO | B | — |
| `UNUserNotificationCenter` | `UsageAlerts`、`SettingsView` | `libnotify`（`Notify` D-Bus） | B | 【待验】Deepin 通知守护进程行为 |
| `pulse://` URL scheme | `Scripts/bundle.sh` | `.desktop` 中 `MimeType=x-scheme-handler/pulse` + `xdg-mime` | B | — |
| `os.Logger` | 2 文件 | `swift-log` 或直接 stderr | A | — |
| `autoreleasepool`（16 处） | 分散 | `#if canImport(ObjectiveC)` 包裹；Linux 下是 no-op | A | 机械替换 |
| `UserDefaults`（74 处） | `AppSettings` 等 | 直接可用 | A | 【实测】落盘 `~/.config/<进程名>.plist` |
| `URL.applicationSupportDirectory` 静态属性 | 3 处 | `FileManager.url(for:.applicationSupportDirectory,…)` | A | 【实测】Linux 无此属性，编译期报错 |
| `SQLite3` 模块 | 9 文件 | SwiftPM `systemLibrary` target + `module.modulemap` | B | 【实测】装 `libsqlite3-dev` 后头文件就位 |

---

## 5. 全流程路线图

每阶段独立可验收、独立提交。**双平台不回归是硬约束**：每个阶段结束都要确认 `main` 分支（macOS 构建）未受影响——因为改动都在 `dev`，实际做法是保证改动仅由 `#if` 或新增文件构成。

### 阶段 0：脚手架与防护网（预计 1–2 天）

| # | 任务 | 验收 |
|---|---|---|
| 0.1 | `.github/workflows/linux-ci.yml`：Linux 上 `swift build` + `swift test`；`ci.yml`（macOS）保持不变 | 两个 workflow 都能跑；Linux 侧允许失败但必须暴露真实错误 |
| 0.2 | `Scripts/linux/swift-env.sh`：Pin 工具链路径，CI 与本地共用 | `source` 后 `swift --version` 输出 6.4 |
| 0.3 | `Docs/linux/` 建目录，本文件迁入 | — |
| 0.4 | 建立上游同步 SOP 文档：`git fetch upstream && git merge upstream/main`，冲突高发区登记 | 文档可执行 |

### 阶段 1：核心层移植（预计 2–3 周）— **最关键**

| # | 任务 | 交付物 | 验收 |
|---|---|---|---|
| 1.1 | **构建骨架**：`Package.swift` 平台条件化（Linux 加 `.linux` 表达、Sparkle 仅 macOS）；新增 `systemLibrary(CSQLite)` target；新增 swift-crypto 依赖 | `swift build` 在 Linux 能进入编译 | 【实测目标】错误数从"模块缺失即中止"降到"可枚举" |
| 1.2 | **文件级条件编译**：60 个 Apple 专属文件整体包 `#if canImport(AppKit)`；`CryptoKit`→`#if canImport(CryptoKit) import CryptoKit #else import Crypto #endif` | Linux 编译通过；macOS 行为不变 | `swift build` 双平台通过 |
| 1.3 | **存储层**：`PulseStorage` 改用 `FileManager.url(for:)`；`LocalSecrets` 换熵源 + swift-crypto；`APIKeyStore`/`AccountCredentials` 打通 | `keys.dat`/`accounts.dat` 在 Linux 读写 | 单测：加密往返、0600 权限 |
| 1.4 | **网络与认证**：`FoundationNetworking`；`LoopbackCallback` 换 POSIX socket；`OAuthLogin` 去掉 AppKit 依赖、`xdg-open` 换 `NSWorkspace.open` | OAuth PKCE 全流程 | 真实跑通一次 Claude Code OAuth 登录 |
| 1.5 | **Readers 路径**：`DatabaseReaderSupport.applicationSupport` 加 Linux 分支；逐个核对 `Library/Application Support/*` → `~/.config/*` | 路径候选表 | 用真实样本目录跑 readers，与 macOS 结果逐字段比对 |
| 1.6 | **Provider 取数**：Claude Code（endpoint + status line）、Codex（endpoint + app-server）、Kimi Code（pasted key）三条链路优先 | 三个 provider 能取到真数据 | 真实账号取数成功 |
| 1.7 | **新增 `pulse --refresh`**（无 GUI 取数入口）：跑一次全量 refresh 并落 `UsageCache`。**对 macOS 是纯增量**，不改现有 `--json` 语义 | CLI | `pulse --refresh && pulse --json` 输出真实数值 |
| 1.8 | **测试**：61 个可移植测试全绿；9 个 GUI 测试条件编译排除 | `swift test` | Linux 全绿且**无跳过**（被排除的应在 macOS 侧仍全绿） |

**阶段一验收（对应 AGENTS.md）** — 实测更新：

- [x] Linux `swift build` 通过
- [x] `swift test` 全绿（717 tests / 75 suites）
- [x] `pulse --refresh && pulse --json` 可用，且真实跑通了 `codex app-server` 的握手与 `account/rateLimits/read`
- [x] 无 `DISPLAY` 环境下上述命令可运行
- [~] 对 Claude Code / Codex 输出**真实数值**：链路已验证到「凭据不足」这一步。本机只有 API key
      没有 OAuth 登录，两个 provider 都如实报 `claudeLoginExpired` / `signInRequired`，
      而直接对 `codex app-server` 发同一个请求得到的是
      `chatgpt authentication required to read rate limits` —— 即结论准确而非移植缺陷。
      要拿到真实数字需要人工跑一次 `codex login` / Claude Code 登录
- [n/a] macOS 构建：本项目只支持 Linux（见「约束」）

**新增的结论：阶段一无法验收「登录 + 取数全流程」。** 登录由设置窗口驱动（阶段二），
当前 `--refresh` 只能用已存在的凭据。详见 `Docs/linux/cli.md` 的「无头登录：目前不存在」。

**总工期估算：3–5 周**，其中 1.5（路径核对）和 1.6（provider 取数）是不可压缩的实测工作，占一半以上。

### 阶段 2：悬浮窗 UI（预计 3–4 周）

先做技术验证再动手 —— 这一阶段的**全部风险集中在协议层**，不在代码量。

| # | 任务 | 验收 |
|---|---|---|
| 2.1 | **协议验证 spike**（先于一切编码）：写最小 GTK4 + `gtk4-layer-shell` demo，在 X11 / Sway / Hyprland / KDE Plasma Wayland / GNOME Wayland 上各跑一次，记录：能否贴边、能否置顶、能否不抢焦点、多显示器能否跟随 | 一张实测矩阵表，作为后续选型的依据。**AGENTS.md 明确要求"先实验再写结论"** |
| 2.2 | UI 进程骨架：读 `pulse --json` + IPC 订阅刷新；多显示器活动跟随 | 圆环数值与 `pulse --json` 完全一致 |
| 2.3 | 圆环绘制（cairo）：4 种颜色态、pinned window、spent 态 | 与 macOS 截图逐项比对 |
| 2.4 | 悬停展开详情卡片：进入靠 `GtkEventControllerMotion`，离开靠指针轮询（对齐上游"不用 exit 事件"的经验） | 真实鼠标操作验证，不用合成事件 |
| 2.5 | 拖拽 + 贴边吸附 + 位置持久化 | 重启后位置保持 |
| 2.6 | 设置窗口（14 个文件 / 5,802 行）+ 首次运行 provider 选择器 | 能增删 provider、粘贴 key、看诊断 |
| 2.7 | BotMark 动画（15 文件）— **可延后或砍掉** | 见 §8 |

**阶段二验收**：X11 与 Wayland 各测一次；悬浮窗贴边、置顶、悬停展开；数值与 `--json` 一致。

### 阶段 3：系统集成（预计 2 周）

| # | 任务 |
|---|---|
| 3.1 | XDG autostart：`~/.config/autostart/pulse.desktop`，首次运行询问（对齐上游"只问一次"的语义） |
| 3.2 | 托盘图标：StatusNotifierItem（`ksni` / `libayatana-appindicator`）——同时是 Wayland 下全局快捷键缺失的降级入口 |
| 3.3 | 全局快捷键：X11 `XGrabKey`；Wayland 降级为托盘 + 文档说明 |
| 3.4 | 通知：`libnotify`，保留全部告警规则（`UsageAlerts` 是纯逻辑，规则可原样移植） |
| 3.5 | 本地化：5 语言迁移，保留 `check-localization.sh` 的键完整性校验 |
| 3.6 | 打包：`.deb`（`dpkg-deb`）+ AppImage；依赖清单（`libgtk-4-1`、`gtk4-layer-shell`、`libsqlite3-0`、`libnotify4`、`libsecret-1-0`） |
| 3.7 | README（Linux 章节）+ 已知差异与限制文档 |

### 阶段 4：CI 与发布（预计 1 周）

- GitHub Actions 产出 `x86_64` / `aarch64` 构建产物（`aarch64` 用 QEMU 或交叉编译）
- Ubuntu 24.04 容器内冒烟：安装 `.deb` → `pulse --refresh` → `pulse --json`
- 头部无头（Xvfb）GUI 冒烟测试

---

## 6. UI 技术选型

### 6.1 Wayland 下的硬约束（决定了选型）

| 合成器 | `wlr-layer-shell` | 后果 |
|---|---|---|
| Sway / Hyprland / river / Wayfire | ✅ | 完整贴边 + 置顶 + 不抢焦点 |
| KDE Plasma (KWin) | ✅（自 5.25） | 同上 |
| GNOME / Mutter | ❌ | **只能退化为普通置顶窗口**，会被全屏应用遮挡，位置受限 |
| Deepin DDE (Treeland/自研) | 【待验】 | 需实测 |

X11 下无此问题：`override-redirect` + `_NET_WM_STATE_ABOVE` + `_NET_WM_STATE_SKIP_TASKBAR` 就是 `NSPanel` 的等价物。

### 6.2 推荐方案：GTK4 (+ `gtk4-layer-shell`) 独立进程

```
┌─────────────────────────────────────────┐
│  pulse (Swift, 无 GUI)                  │
│  ├─ Providers (20)  ├─ Readers (56)     │
│  ├─ Auth            ├─ UsageCache       │
│  └─ --refresh / --json / --statusline   │
└──────────────┬──────────────────────────┘
               │  ① `--json` 契约（已有，稳定）
               │  ② Unix domain socket JSON-lines（新增）
               │     订阅刷新 / 读写设置 / 触发登录
┌──────────────▼──────────────────────────┐
│  pulse-shell (GTK4 + layer-shell)       │
│  ├─ 边缘圆环面板（cairo 绘制）           │
│  ├─ 悬停详情卡片                        │
│  ├─ 设置窗口 / 首次运行选择器            │
│  └─ 托盘图标（StatusNotifierItem）       │
└─────────────────────────────────────────┘
```

- 核心层可在无显示环境运行、测试、进 CI
- UI 崩溃不影响取数与缓存
- `--json` 契约继续对外服务（sketchybar / Raycast 等集成不受影响）
- 上游 Providers 的修复通过 `git merge upstream/main` 直接落地，无需碰 UI

### 6.3 备选方案对比

| 方案 | 优势 | 劣势 | 结论 |
|---|---|---|---|
| **GTK4 + Rust (`gtk4-rs`)** | 绑定一流且活跃；纯静态单二进制；CI 交叉编译成熟；`ksni` 托盘库成熟 | 引入 Rust 工具链；两种语言 | **推荐** |
| GTK4 + C | 无新运行时依赖；与 GTK 同语言 | 内存管理手工；GTK4 信号样板冗长；开发速度慢 | 可接受，若不愿引入 Rust |
| GTK4 + Vala | GTK 原生；编译为 C | 工具链冷门；生态小 | 不推荐 |
| GTK4 + Python | 迭代最快；PyGObject 成熟 | 打包依赖重；常驻内存高；分发体验差 | 原型可用，生产不推荐 |
| Swift 直连 GTK4 C API | **单一语言**；复用现有 Swift 知识 | GObject 信号需手写 trampoline；业界零先例；维护经验无处借鉴 | 高风险，不推荐首版 |
| Qt6 / QML | X11 表现好；`LayerShellQt` 可用 | 与 Swift 核心仍是双进程；Qt 依赖体积大 | 可行备选 |
| egui / iced (Rust) | 立即模式绘制圆环很顺手 | **layer-shell 无原生支持**，需手写 smithay-client-toolkit；Wayland 下等于自己造 | 不推荐 |

### 6.4 X11 与 Wayland 行为差异（预期，待 2.1 实测确认）

| 行为 | X11 | Wayland |
|---|---|---|
| 窗口定位 | 精确到像素 | layer-shell 下由 anchor + margin 决定；普通窗口下**合成器完全接管，无法精确放置** |
| 始终置顶 | `_NET_WM_STATE_ABOVE` | layer-shell `LAYER_TOP`；普通窗口无客户端可控保证 |
| 不抢焦点 | `override-redirect` | layer-shell `set_keyboard_interaction(NONE)` |
| 全局快捷键 | `XGrabKey`，可靠 | **无统一协议**；KDE 可经 KGlobalAccel，其余需用户自行在 compositor 配置 |
| 多显示器 | `Xinerama`/`RandR` 查询 + 自由放置 | GDK monitor 查询可用，放置受 anchor 约束 |
| 透明背景 | compositor 需支持，需 `_NET_WM_WINDOW_OPACITY`/ARGB visual | 原生支持 |

---

## 7. 关键风险

| # | 风险 | 概率 | 影响 | 缓解 |
|---|---|---|---|---|
| R1 | **GNOME Wayland 无法贴边置顶** | 确定 | 高 | 阶段 2.1 先实测；README 列为已知限制；提供"降级为普通置顶窗口"模式 |
| R2 | **上游 Provider 快速变化导致 merge 冲突** | 高 | 中 | 文件级 `#if` 包裹（改动集中在文件头尾，内部编辑仍可自动合并）；CI 里加"上游可合并性"检查 |
| R3 | **Reader 路径映射错误导致静默读到 0 条记录** | 高 | 高 | 上游设计上"读不到就产出空记录而非 0"（防误报），反而会掩盖路径错误。必须用**真实样本数据 + 逐字段比对**做验证，不能只看"没报错" |
| R4 | **Chromium cookie 解密在 Linux 行为不同** | 中 | 中 | 影响 Ollama Cloud / Xiaomi / Devin / Cursor / Grok Bot。**必须在真实 Linux Chrome 上实测**（尤其 Chrome 127+ 的 `app_bound_encryption`）。降级方案：手动粘贴 cookie 头 |
| R5 | **Wayland 全局快捷键不可行** | 高 | 低 | 托盘菜单降级，符合 AGENTS.md 允许的降级路径 |
| R6 | **`LocalSecrets` 密钥跨平台不通用** | 确定 | 低 | 设计特性；文档说明迁移需重填 key |
| R7 | **macOS 侧被意外破坏** | 中 | 高 | 全部改动限定在 `dev`；`#if` 包裹不改 macOS 分支代码；CI 双平台；每次提交前 review diff 是否含非条件化改动 |
| R8 | **BotMark 动画（15 文件）纯手工重写成本高** | 高 | 低 | 首版砍掉，用静态图标替代；后续按需补 |
| R9 | **aarch64 CI 构建** | 中 | 中 | QEMU 或 GitHub 原生 arm64 runner |
| R10 | **设置窗口 14 文件 / 5,802 行工作量被低估** | 高 | 中 | 阶段二按 pane 拆分交付，先做 provider 选择 + key 输入这两个阻塞首次运行的最小集 |

---

## 8. 建议砍掉 / 延后的范围

按"核心体验优先"原则，首版 Linux 版建议：

| 功能 | 处理 | 理由 |
|---|---|---|
| BotMark 动画（15 文件，约 4,200 行） | **首版砍掉** | 纯装饰性；cairo 逐帧重写成本高；不影响验收标准 |
| Sparkle 自动更新 | 移除 | AGENTS.md 明确要求 |
| 状态栏图标（`NSStatusItem`） | 换成托盘 | 语义等价 |
| Money 估算 / spend 图表 | **延后到阶段 3 之后** | `Docs/token-spend.md` 是独立大子系统，不阻塞验收 |
| Raycast / sketchybar 集成 | 保留 `--json` 即可 | Linux 用户可用 `waybar` / `polybar` 自建 |
| Claude Code status line hook | **保留** | 是实现成本最低、价值最高的一条取数链路 |
| `pulse://` URL scheme | 保留 | 设置页深链，成本低 |

---

## 9. 工作量与时间线

| 阶段 | 内容 | 估算 | 累计 |
|---|---|---|---|
| 0 | 脚手架与防护网 | 1–2 天 | 1–2 天 |
| 1 | 核心层移植 | 3–5 周 | 3–5 周 |
| 2 | 悬浮窗 UI | 3–4 周 | 6–9 周 |
| 3 | 系统集成 | 2 周 | 8–11 周 |
| 4 | CI 与发布 | 1 周 | 9–12 周 |

**阶段一结束即可交付 `pulse --json` + `pulse --refresh`**，对没有 GUI 需求的用户（tmux / waybar 用户）已经是可用产品。

---

## 10. 待你确认的决策点

1. **路线是否采纳**"Swift 核心 + 独立 GTK4 UI 进程"？
2. **UI 语言**：Rust（`gtk4-rs`，推荐）／ C ／ Swift 直连 C API？
3. **BotMark 动画**是否同意首版砍掉？
4. **目标发行版优先级**：AGENTS.md 验收标准写的是 Ubuntu 24.04 双会话测试。本机是 Deepin 25。是否需要我现在起一个 Ubuntu 24.04 容器/虚拟机用于阶段 2 的协议验证？

> §5 阶段 2.1 的协议验证 spike 是**最该先做的事**：它把 R1（GNOME Wayland）从"猜"变成"测"，成本约半天，却能决定整个 UI 方案是否需要准备两套降级路径。
