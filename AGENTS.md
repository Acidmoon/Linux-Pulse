# 任务：将 Pulse（macOS 悬浮窗 AI 用量监视器）迁移到 Linux

## 背景
- 上游仓库：https://github.com/qunqin24/Pulse（remote 名 `upstream`）
- 本仓库：https://github.com/Acidmoon/Linux-Pulse（remote 名 `origin`），**就是该项目的 fork**
- 本地绝对路径：`~/Coding/Linux-Pulse`（仓库根目录，即 SwiftPM 包根目录）
- 这是一个原生 Swift / SwiftUI 的 macOS 屏幕边缘悬浮监视器，实时展示 Claude Code、Codex、OpenCode Go、Kimi Code 等 19+ 个 AI 编程工具的额度/用量。
- 除在线 API 外，它还通过解析本地会话日志（~/.claude、~/.codex 等）统计 token 消耗（Sources/Pulse/Usage/Readers 下约 50 个 Reader）。
- 它依赖大量 macOS 专属 API：AppKit/NSPanel/SwiftUI、Keychain、SMAppService（开机自启）、Sparkle（自动更新）、全局快捷键、x86_64/arm64 codesign、appcast 更新通道。
- SwiftUI/AppKit 在 Linux 上不存在。Swift 核心库（Foundation、URLSession 对应物、并发）在 Linux 可用，但 UI 层必须重写。

## 分支模型
| 分支 | 作用 | 上游跟踪 |
|---|---|---|
| `main` | 纯上游镜像，**不在此分支提交** | `upstream/main` |
| `dev` | 全部 Linux 迁移工作 | `origin/dev` |

- 同步上游：`git fetch upstream && git merge upstream/main`（在 `main` 上执行，再 merge 进 `dev`）
- 推送：`git push`（`remote.pushDefault = origin`，`push.default = current`）
- 注：上游 `AGENTS.md` 内容为 `@CLAUDE.md`（一行指针），本文件在 `dev` 分支上取代了它；仓库级 agent 指引仍在 `CLAUDE.md`。

## 你的角色与流程要求
1. **先评估，再动手**：通读代码，输出一份《Linux 迁移评估报告》：
   - 逐模块标注：可直接移植 / 需条件编译改造 / 必须重写（尤其 Sources/Pulse/App、Auth、Panel 三个目录）。
   - 列出所有 macOS 专属 API 及其 Linux 替代方案。
   - 给出技术路线建议（保留 Swift 核心 + Linux GUI / 换语言整体重写），说明工作量、风险和维护性，让用户确认后再进入实现。
2. 确认路线后，**分阶段交付**，每阶段可独立验证。

## 迁移目标形态
- 还原 macOS 版核心体验：**贴屏幕边缘的悬浮用量圆环面板**（always-on-top、透明背景、悬停展开详情卡片），随活动显示器/多显示器移动。
- UI 技术选型由你评估决定（GTK/Qt/egui 均可），但必须支持 X11 和 Wayland，给出在两种会话下的行为差异说明。

## 必须处理的 macOS → Linux 替代映射
| macOS 机制 | Linux 替代 |
|---|---|
| Keychain / LocalSecrets | Secret Service API（libsecret / secret-tool），无服务时降级到 0600 权限文件 |
| SMAppService 开机自启 | XDG autostart（~/.config/autostart/*.desktop） |
| Sparkle 自动更新 | 移除更新逻辑；改用系统包管理或 GitHub release 手动更新，README 说明 |
| NSPanel 悬浮窗 | GTK/Qt 的 override-redirect / layer-shell 无边框置顶窗口 |
| 全局快捷键（EventTap） | X11: XGrabKey / Wayland: compositor 全局快捷键协议；无法统一时降级为托盘菜单触发 |
| Chromium 浏览器 Cookie 读取 | Linux 路径：~/.config/chromium、~/.config/google-chrome、Brave/Edge 对应目录；注意 Chrome 127+ 的 app_bound_encryption 在 Linux 上的差异 |
| 本地化资源（*.lproj） | 迁移为 Linux UI 框架自己的 i18n 机制，保留 en/zh-Hans/zh-Hant/ja/ko |
| codesign / xattr | 不需要，直接产出可执行文件 + .desktop 文件 |

## 核心层要求（无论选哪条路线）
- **Providers 与 Readers 是最大资产**，必须完整保留 19+ Provider 和全部本地日志 Reader 的行为；它们读的路径（~/.claude、~/.codex 等）在 Linux 上同样存在。
- 保留 `pulse --json` 脚本化输出能力——这是无 GUI 环境下最可靠的验证入口。
- 网络层（OAuth、API key、VolcengineSigner、LoopbackCallback 本地回调等）在 Linux 上跑通真实登录流程。
- 配置/设置项语义不变，迁移用户现有配置文件。

## 分阶段交付
1. **阶段一：核心移植**——纯逻辑层（Models + Providers + Readers + Auth）在 Linux 编译通过，单测全绿，至少跑通 Claude Code 和 Codex 两个 Provider 的 `pulse --json`。
2. **阶段二：悬浮窗 UI**——实现边缘悬浮圆环 + 悬停详情面板，多显示器跟随。
3. **阶段三：系统集成**——自启、托盘/快捷键、本地化、README 与 Linux 安装文档（含依赖清单）。
4. **阶段四：CI**——GitHub Actions 产出 Linux x86_64 / aarch64 构建产物。

## 验收标准
- [ ] 在干净的 Linux 环境（Ubuntu 24.04 + Wayland 和 X11 各测一次）可安装运行
- [ ] 悬浮窗贴边显示，圆环数值与 `pulse --json` 输出一致
- [ ] 至少 Claude Code、Codex、Kimi Code 三个 Provider 登录 + 取数全流程可用
- [ ] 本地日志统计（token 消耗）与 macOS 版读同一目录下的样本数据结果一致
- [ ] 无 GUI 环境下 `pulse --json` 正常工作
- [ ] 提供迁移文档：架构图、macOS API 替代对照表、已知差异与限制

## 约束
- 不要改动 macOS 版现有行为；新代码用条件编译（如 `#if canImport(AppKit)`）或目录隔离，保证 macOS 构建不受影响。
- 不臆造 API 行为：对不确定的 Linux 桌面行为（如 Wayland 下的窗口定位限制），先实验再写结论。
- 每完成一个阶段，用 git 提交并写清 commit message；最终交付完整 fork 仓库或可合并的分支。

## 环境备忘（Deepin 25 / x86_64）
- OS：Deepin 25（`crimson`，Debian 系），glibc **2.38**
- 当前会话：**X11**（`XDG_SESSION_TYPE=x11`，`DISPLAY=:0`）；Wayland 需另测
- `gh` 已登录 `Acidmoon`（scopes: repo, gist, read:org），`gh auth setup-git` 已配置为 git credential helper
- 硬件：4 核 / 15 GB RAM / `/home` 余量 ~104 GB

### Swift 工具链（已装并验证）
```
版本   : Swift 6.4 (swift-6.4-RELEASE), target x86_64-unknown-linux-gnu
发行包 : swift-6.4.0-RELEASE-ubuntu22.04.tar.gz  （Ubuntu 22.04 build）
路径   : ~/.local/share/swift/tc/swift-6.4.0-RELEASE-ubuntu22.04
PATH   : 已写入 ~/.bashrc 的 "Swift 6.4 toolchain" 段（新交互 shell 生效）
```
选 Ubuntu 22.04 build 而非 24.04：24.04 build 要求 glibc ≥ 2.39，本机 2.38 不满足；22.04 build 要求 ≥ 2.35，实测可用。（Swift 官方 6.4 亦提供 Ubuntu 26.04 build 与 Static SDK。）

实测结论（`swiftc -typecheck` / 冒烟程序，2026-09-22）：

| 模块 | Linux 可用性 | 备注 |
|---|---|---|
| Foundation, FoundationNetworking | ✅ | `URLSession` 需显式 `import FoundationNetworking` |
| Observation | ✅ | 6 个文件在用 |
| swift-testing (`import Testing`) | ✅ | 工具链自带，70 个测试文件用 |
| SQLite3 | ⚠️ | 工具链**不带** `SQLite3` modulemap，且 `/usr/include/sqlite3.h` 缺失（未装 `libsqlite3-dev`） |
| CryptoKit / CommonCrypto | ❌ | 需改用 swift-crypto 提供的 `Crypto` 模块 |
| AppKit / SwiftUI / Carbon / CoreGraphics / IOKit / Security / ServiceManagement / Sparkle / Network / os / UserNotifications / Darwin | ❌ | 全部需要替代方案或重写 |

### 已知的构建前置缺口
- `libsqlite3-dev`（`/usr/include/sqlite3.h`）缺失，且本机 `sudo` 需要密码 → **需要用户执行**：
  `sudo apt install libsqlite3-dev`（另有 `libcurl4-openssl-dev`、`libxml2-dev`、`libedit-dev`、`clang` 视情况）
- 全库**当前零条件编译**（`Sources/` + `Tests/` 中 `#if canImport` / `#if os(` 出现 0 次），即现状完全无法在 Linux 编译

### Linux 构建的两个坑（实测 2026-09-22）

**1. swift-crypto 需要 C++ 头文件。** CryptoKit 的 Linux 替代 swift-crypto 内嵌 BoringSSL，编译它需要 `<memory>`。
本机装了 `gcc-13` + `libgcc-13-dev` 但**没装** `libstdc++-13-dev`，于是工具链的 clang 挑中 GCC 13、去找
`/usr/include/c++/13/`，不存在 → `fatal error: 'memory' file not found`。

永久修复（需要 sudo）：

```bash
sudo apt install g++-13          # 或 libstdc++-13-dev
```

临时绕过（不改仓库、已验证可用）：

```bash
swift build -Xcc --gcc-install-dir=/usr/lib/gcc/x86_64-linux-gnu/12
```

**2. `swift build` 的批量编译会「涓流」报错。** Swift 的批量编译模式在第一个模块错误处就中止该批次，
所以一次 `swift build` 只会暴露一小撮 `no such module 'X'`，不能用来枚举完整工作队列。
枚举要靠在全树 `grep` import，或用 `swiftc -typecheck` 逐文件跑。
