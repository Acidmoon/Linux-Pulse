# 上游同步 SOP

本仓库是 [`qunqin24/Pulse`](https://github.com/qunqin24/Pulse) 的 fork。上游每周都在跟着各家的账号端点变化修 Provider，**能持续 merge 是这个项目最重要的资产**。这份文档的存在是为了让那条路一直走得通。

## 分支模型

| 分支 | 作用 | 上游跟踪 |
|---|---|---|
| `main` | 纯上游镜像，**不在此分支提交** | `upstream/main` |
| `dev` | 全部 Linux 迁移工作 | `origin/dev` |

```
origin   = Acidmoon/Linux-Pulse   （fork，推送目标）
upstream = qunqin24/Pulse         （只读同步源）
```

配置（已设置，换机器时要重建）：

```bash
git remote rename origin upstream
git remote add origin https://github.com/Acidmoon/Linux-Pulse.git
git config remote.pushDefault origin
git config push.default current
git config branch.main.remote upstream
git config branch.main.merge refs/heads/main
```

## 同步流程

```bash
# 1. 先确认工作区干净
git status --short

# 2. 让 main 跟上上游
git checkout main
git fetch upstream --tags
git merge --ff-only upstream/main      # 不是 ff 说明 main 被污染了，停下来查
git push origin main                   # 让 fork 的 main 也跟上

# 3. 合进 dev
git checkout dev
git merge main

# 4. 解决冲突（见下），然后验证双平台
source Scripts/linux/swift-env.sh
swift build && swift test
#    macOS 侧由 .github/workflows/ci.yml 验证；本地没有 macOS 时靠 CI

git push
```

## 冲突高发区与应对

上游改动只要落在我们没碰过的文件里，合并就是自动的。真正会冲突的只有下面几处，都是我们**必然**要改的文件：

| 文件 | 我们改了什么 | 冲突形态 | 应对 |
|---|---|---|---|
| `Package.swift` | 平台条件化、新增 `CSQLite` target、Linux 加 swift-crypto | `dependencies` / `targets` 数组被双方改写 | 上游改 Sparkle 版本或加依赖时，把新内容放回 `#if os(macOS)` 分支；上游加 target 时同时加到两边 |
| `AGENTS.md` | 上游内容是 `@CLAUDE.md` 一行，被我们换成了迁移任务书 | 必然冲突（对方极少改） | 取我们的版本（`git checkout --ours AGENTS.md`）；`CLAUDE.md` 保持上游原文 |
| `.gitignore` | 加了 Linux 产物段 | 少见 | 两边都保留 |
| `Sources/Pulse/**/` 被 `#if canImport(AppKit)` 包裹的文件 | 文件头尾各加一行 | **通常自动合并**——上游对这些文件的编辑都在 `#if` 内部 | 若冲突，取上游正文 + 保留首尾包裹 |

### 为什么用文件级 `#if canImport(AppKit)` 而不是 SwiftPM `exclude:`

上游 `CLAUDE.md` 有一条约束：文件所在目录就是它归属的声明，SwiftPM 会递归。把 Linux 该排除的文件写进 `Package.swift` 的 `exclude:` 是最省事的做法，但**上游每新增一个 UI 文件都会立刻打破 Linux 构建**，而且那个列表会无限增长。

文件级包裹的代价是要改 60 个文件，换来的是：上游在这些文件内部的任何编辑都能自动合并，我们只在文件首尾各占一行。

### 为什么核心层留 Swift 而不是翻译成别的语言

见 `migration-assessment.md` §1.1。一句话：翻译 = 永久切断上游血缘 = 接手 20 个会腐烂的爬虫。

## 每次同步后要做的检查

- [ ] `git log --oneline upstream/main ^dev | head` 为空（即确实跟上了）
- [ ] `swift build` + `swift test` 在 Linux 通过
- [ ] macOS CI（`.github/workflows/ci.yml`）在 PR 上通过
- [ ] 上游若有 Provider 改动，跑一次 `pulse --refresh && pulse --json` 确认取数仍正常
- [ ] 上游新增的 Provider：补 `ProviderDiscovery` 的 Linux 路径候选、补 `Docs/linux/` 里的路径映射表
