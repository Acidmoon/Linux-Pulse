# 无 GUI 命令行接口

先装一次，`pulse` 才是命令：

```bash
Scripts/linux/install.sh        # 装到 ~/.local，并把 ~/.local/bin 加进 PATH 的提示打出来
```

没装之前，下面所有 `pulse` 都要写成 `./.build/release/Pulse`（注意大写 P）。
详见 `Docs/linux/install.md`。

阶段一的交付物就是这一节的两个命令。它们合起来是完整的无头面：**`--refresh` 把数字放进去，`--json` 把数字读出来。**

`--json` 的输出格式契约属于上游，不在本文档里重复：
[../json-output.md](../json-output.md)。

## `pulse --refresh`

问一遍所有已启用的 provider，然后退出。

```bash
pulse --refresh          # 诊断写到 stderr，stdout 保持干净
pulse --refresh && pulse --json | jq '.accounts[] | "\(.name) \(.headline.usedPercent // "–")"'
```

**它必须存在。** 上游的 `--json` 刻意只读缓存、从不取数——因为它被设计成状态栏每两秒调用一次，
在这个频率下开连接、碰凭据比不做还糟。那就在无头安装里留下了缺口：没有任何东西能填缓存。
`--refresh` 就是填它的那一个。

**它的语义是一次「启动」，不是一次「轮询」。** 启用集合通过 `AppSettings.restored()` 解析，
它顺路会写下 `hasRun` 和 offered 列表——这正是 app 每次启动做的事，也正是 `--json` 改走
`storedRail()` 的原因。所以在一个从未运行过 app 的安装上，它找不到任何已启用的 provider 并如实说明，
而不是替你猜该开哪些。

### 输出

逐账号一行，按 rail 顺序，缩进对齐：

```
Pulse: asking 2 accounts…
  claudeCode  unavailable: claudeLoginExpired
  codex       unavailable: signInRequired
Pulse: 0 of 2 answered in 0.4s.
```

有读数时那一列是**环上会显示的那个百分比**（走 `headlineWindow()`，与环同一个判断），
已用尽会加 `(spent)`。没有读数时打印 `unavailable: <token>`，token 就是 `--json` 里用的那个，
所以两者不可能对同一件事给出不同说法。**没有读数就不编数字**——不打印 0%。

全部写到 **stderr**，stdout 保持干净，所以 `--refresh && --json | jq` 不会变成两份文档交错。

### 退出码

| 码 | 含义 |
|---|---|
| 0 | 一轮跑完并静置（settle）。**单个 provider 失败仍是 0**——那是正常结果，按账号记在缓存里，属于 `--json` 的表达范围 |
| 1 | 没有任何已启用的 provider，或 180 秒上限到了 |

超时上限 180 秒是针对**整轮**而非单个请求的：一轮里每个请求本来都有自己的超时且并行跑，
`UsageStore.passCeiling` 取 180 秒也是同一个理由——超过这个时间它就不是慢，而是丢了。
超时不丢数据：已经到的都留在缓存里，`--json` 会照常打印，只是给出了非零退出码。

## `pulse --json`

读缓存并打印，**从不取数**。完整契约见上游文档。要在无头环境看到数字，先跑 `--refresh`。

## `pulse --set-key <provider>` / `--clear-key <provider>`

**key 从 stdin 读，永远不作为命令行参数。** 参数对机器上每个用户都在 `ps` 里可见，且默认会写进 shell 历史；
`gh auth login --with-token` 出于同样理由从 stdin 读，这个命令沿用它的形状。

```bash
pulse --set-key kimiCode
<paste, then Enter>
```

**key 本身不回显。** 命令只报告是哪个 provider、有没有落盘。它写进 `keys.dat`，用本机标识符封存。

存 key 的同时会**把该 provider 打开**——一条没有任何东西去问的 key 等于不存在，
而这是本命令唯一一处改设置而非存密钥的地方，所以它会明说。

11 个 provider 接受粘贴的 key（Kimi Code、DeepSeek、MiniMax、MiniMax CN、z.ai、GLM Coding Plan、
OpenCode Go、Command Code、Volcengine、Devin、Ollama Cloud 的会话 cookie）。
不接受的那些会**明确说明理由**而不是静默失败——Copilot 是 GitHub 设备登录，
Cursor / Grok Bot / Devin 读的是别的程序存的登录，Antigravity / Kiro 读的是必须正在运行的 helper。

退出码：0 成功；1 空 key 或写入失败；2 provider 缺失、名字写错、或该 provider 不接受 key。

## `pulse --enable <provider>` / `--disable <provider>`

决定悬浮窗的轨道上显示哪些圆环。

```bash
pulse --providers              # 列出全部 Provider，● 在轨道上 / ○ 已关闭
pulse --enable kimiCode        # 打开一个
pulse --disable cursor         # 关掉一个
```

名字**大小写不敏感，也接受显示名**——`kimiCode`、`kimicode`、`Kimi Code`
指的是同一个。原始值是驼峰写法，要求用户记住哪几个字母大写没有道理。

在 Linux 上这不是可有可无的便利：macOS 版靠设置窗口选 Provider，而 Linux
版没有设置界面，此前唯一的办法是手工编辑 `~/.config/Pulse.plist`。
对一个本职就是"显示"的程序来说这是个糟糕的答案。

`--enable` 不能用于 Kimi Code 之外的情况——`--set-key` 在存下密钥后会自动
启用对应的 Provider，所以有密钥可设的 Provider 走那条路即可。Kimi 是例外：
它借用本机 CLI 已有的登录，没有密钥可设，因此需要一个独立的开关。

退出码：`2` 名字不对或缺失，`1` 开关被拒绝，`0` 成功。

**最后一个圆环关不掉。** 轨道空着不是一个能通过"删掉最后一项"到达的状态，
`AppSettings.enabledAccounts` 的 `didSet` 会拒绝清空并还原。关掉唯一在轨的
Provider 会返回 `1` 并说明原因。

## `pulse --place` / `--position` / `--autostart` / `--quit`

控制悬浮窗本身。**这些在面板已经运行时立刻生效，不需要杀掉重启。**

```bash
pulse --place left            # left | right | top | float
pulse --position 0.5          # 0 = 起点，0.5 = 居中，1 = 末端
pulse --autostart on          # 登录时自动启动（XDG autostart）
pulse --quit                  # 关掉正在运行的面板
```

`--position` 只有一个数，因为**只有一条轴上的比例是有意义的**：贴边的面板在它贴着
的那条轴上固定、在另一条轴上居中，所以一条左边缘的轨道只有一个自由度，它的名字
就叫垂直比例。浮动的面板两条比例都有用，此时 `--position` 设的是垂直那条——人说
"放中间"时指的就是它。

`--quit` 什么都不在跑时返回 `1`："我停掉了它"和"没有东西可停"是两个不同的答案，
脚本可能在意。

### 生效机制：一个信号，而不是轮询

`--place` 写完设置后给面板发 `SIGUSR1`，面板在**主循环上**（`g_unix_signal_add`，
不是 `signal()`）收到后重读设置、请求新的窗口尺寸、重新定位。用 `signal()` 的话
处理器会跑在内核随便挑的线程上，而它要做的是移动窗口——那是和绘制之间的数据竞争。

### 为什么面板自己读文件

**这是实测的结论，不是设计偏好。** `UserDefaults` 在 Linux 上看不到别的进程写的
东西。探针：一个进程持有 suite，另一个进程改它的 plist，第一个进程在改之前读到
`nil`、改完三秒后仍读到 `nil`、连**重建实例**后还是 `nil`；而同一个实例能读到自己
写进去的键。swift-corelibs-foundation 在进程内按 suite 名缓存已解析的域，把同一个
还给你。只有文件里有新值。

所以 `PanelPlacement.reloaded()` 和 `AppSettings.adoptCommandLineSettings()` 直接读
plist（`SettingsFile`），`restored()` 那条路在 Linux 上做不到这件事。

macOS 上不需要这些：`cfprefsd` 存在的意义就是让一个进程的写成为另一个进程的读。

### 第二个实测结论：`UserDefaults` 不会自己落盘

`--enable` 写完设置后进程就退出了，而 `UserDefaults` 是"先写内存、之后才到磁盘"，
所以那次写入随进程消失。`pulse --enable kimiCode` 打印了"2 on the rail"，下一条命令
读到的文件里还是一个——**这个缺陷早就在 `--set-key` 里**，它存下密钥后会启用对应
Provider，那次启用一直是丢的。现在在 `PulseCLI.run()` 唯一的出口处 flush 一次。

## `pulse --help`

打印用法并以 `0` 退出。

**此前 `--help` 会启动悬浮窗。** 所有模式都靠
`CommandLine.arguments.contains(...)` 判断，没匹配上的一律落到"启动悬浮窗"，
而悬浮窗是前台阻塞的——于是在任何装了组件的机器上（也就是所有机器），用法
文本都读不到。

## 设置文件与 `PULSE_DEFAULTS_SUITE`

设置存在 `~/.config/Pulse.plist`（macOS 上是 bundle 自己的 domain）。删除该
文件即可重置。

跑测试时用 `Scripts/linux/test.sh`，或自己带上
`PULSE_DEFAULTS_SUITE=pulse-tests`：

```bash
PULSE_DEFAULTS_SUITE=pulse-tests swift test
```

**因为测试会写设置。** 整个程序都通过 `PulseDefaults.shared` 这一个
`UserDefaults` 读写，所以改设置就是改开发者的设置——`swift test` 跑完会把
`~/.config/Pulse.plist` 留成某个 fixture 的 `['codex#test']`，盖掉本来选好的
轨道。这个变量把那些写入指向一个用完即弃的 suite。CI 也设置了它。

## 无头登录：目前不存在

**这是当前阶段一的真实缺口，不是待办的口头承诺。**

登录流程由设置窗口驱动：`Auth/OAuthLogin.swift` 用的是系统浏览器 + 回环端口回调 + `pulse://` 回跳，
发起者是设置里的一个按钮。设置窗口属于阶段二。所以今天 `--refresh` **只能用已经存在的凭据**：

- 能读的：`~/.claude/.credentials.json`、`~/.codex/auth.json`、`~/.grok/auth.json`、
  `~/.commandcode/auth.json`、`~/.pi/agent/auth.json`（Kimi Code）、
  `~/.kimi-code/credentials/kimi-code.json`（Kimi Code CLI）、`~/.config/*` 下的既有 key，
  以及 `keys.dat` 里粘贴过的 key
- 不能做的：新登录、**刷新**过期的 OAuth token

  「不刷新」是刻意的：两个 Kimi 凭据存储都在 access token 旁边放了 refresh token，
  而 OAuth 的 refresh token 会轮换——花掉一个会让持有它的那个工具手里那份失效，
  等于把人从 Pi 或 CLI 里踢出去。所以过期就报过期（`kimiLoginExpired`），续期是拥有者的活。
  Kimi Code 的两个存储**同时读、取更新的那个**，因为两者单位不同（Pi 用毫秒、CLI 用秒）
  且 token 不同——实测为 648 与 677 字符、值也不同。

在实测机器上的表现（这台机器有 `claude` 与 `codex` 两个 CLI，但只有 API key）：

```
claudeCode  unavailable: claudeLoginExpired
codex       unavailable: signInRequired
```

两者都是**准确**的，不是移植缺陷：`~/.claude/.credentials.json` 里只有一条 `mcpOAuth`，
没有 Claude Code 的登录；`~/.codex/auth.json` 里只有 `OPENAI_API_KEY`。直接对真实的
`codex app-server` 跑一遍握手，它自己回答：

```
{"error":{"code":-32600,"message":"chatgpt authentication required to read rate limits"},"id":2}
```

`signInRequired` 对应的补救动作是 `codex login`（`ConnectionRemedy` 给出的就是这条），
它是交互式的，得由人来跑。

## 状态栏模式

`pulse --statusline` 读 stdin、打印一行，被 Claude Code 当作状态栏命令调用；
`pulse --install-statusline` / `--uninstall-statusline` 负责注册与注销。
这条路径从阶段一起就在 Linux 上可用，而且它是**成本最低、价值最高**的一条取数链路：
Claude Code 只在登录新鲜时写端点，而状态栏推送不受此限。

注册会改写 `~/.claude/settings.json`，原状态栏命令会被记下来并继续链式调用。

## 入口约定

`PulseLinuxMain.main()` 是 `async` 的，只为 `--refresh`——它必须 await 一轮取数。
**不能用信号量阻塞主线程**：`UsageStore` 是 main actor 绑定的，在那个线程上握着信号量
会把它正在等的那件事一起停住。其余模式都是同步的，在第一次挂起之前就跑完，
所以状态栏那条路径的开销没有变化。
