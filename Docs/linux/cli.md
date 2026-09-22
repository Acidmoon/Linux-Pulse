# 无 GUI 命令行接口

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

## 无头登录：目前不存在

**这是当前阶段一的真实缺口，不是待办的口头承诺。**

登录流程由设置窗口驱动：`Auth/OAuthLogin.swift` 用的是系统浏览器 + 回环端口回调 + `pulse://` 回跳，
发起者是设置里的一个按钮。设置窗口属于阶段二。所以今天 `--refresh` **只能用已经存在的凭据**：

- 能读的：`~/.claude/.credentials.json`、`~/.codex/auth.json`、`~/.grok/auth.json`、
  `~/.commandcode/auth.json`、`~/.config/*` 下的既有 key，以及 `keys.dat` 里粘贴过的 key
- 不能做的：新登录、刷新过期的 OAuth token

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
