# Linux subprocess: `posix_spawn` + `waitpid`, not `Process`

**Status:** in force. **Evidence:** measured on Deepin 25 / x86_64 / glibc 2.38 / Swift 6.4 against real children. Everything below is a probe result from that machine; none of it has been re-run elsewhere, and the underlying defects are in swift-corelibs-foundation rather than in Pulse, so a toolchain upgrade may change them.

## What went wrong, three times

The provider helpers spawn children — `codex app-server`, `kiro acp`, `arkcli`, the Claude Code status line — and all of them used Foundation's `Process`. Three separate defects surfaced, each in a different helper, and each was diagnosed only after the previous local workaround was in place.

### 1. `readabilityHandler` does not deliver EOF on a pipe that carried bulk data

A child writing more than a pipe buffer left the **busy descriptor's EOF undelivered**, while the quiet descriptor signalled EOF immediately. A `DispatchGroup` waiting on both therefore waited out its entire deadline on a process that had already exited.

It is a race, so *which* descriptor stalled changed run to run. This is why two assertions in the Volcengine suite failed alternately — the caller had one stdout test and one stderr test, and each run one of them hung:

```
round 1  1MB->stderr: EOF out at 0.02s, err never      — timed out at 9.00s
round 1  4MB->stdout: EOF err at 9.11s, out never      — timed out at 18.01s
round 2  1MB->stderr: EOF out at 18.04s, err never     — timed out at 27.01s
round 2  4MB->stdout: EOF err at 27.11s, out never     — timed out at 36.01s
```

One run ended in a crash inside `_dispatch_event_loop_drain`. The same pipelines through a blocking `read` returned in **0.01s, 8 times out of 8**.

### 2. A child whose stdout EOF was seen through a handler is never reaped

`terminate()` kills it correctly — it is dead — but Foundation does not reap it, so it is a zombie and `Process.isRunning` stays `true` for ever. Isolated as a four-cell matrix:

| child | handler | `isRunning` after `terminate()` + 1s | `waitpid(WNOHANG)` |
|---|---|---|---|
| `sleep 30` | none | `false` | gone |
| `sleep 30` | installed | `false` | gone |
| `exec 1>&-; sleep 30` | installed, EOF observed | **`true`** | **zombie** |
| `exec 1>&-; sleep 30` | none | `false` | gone |

Only the third cell — the one that matters, because noticing EOF is the whole point of the Codex reader — is wrong.

### 3. `terminationHandler` therefore does not fire, so `exited.wait(2s)` times out

The tail of the same defect. A Volcengine run that read both pipes successfully still returned `unreachable`: the failure took **3.7s where a readers-timeout would have taken the full 20**, so the pipes were done and the exit was what was not seen.

## What replaced it

`Sources/Pulse/Platform/Subprocess.swift`. `waitpid` is called by that file and nothing else, so an exit is *known* rather than inferred, and `read`/`poll` are called directly, so EOF is a return value rather than a callback that may or may not arrive.

- **`Subprocess.run`** — one-shot with a deadline and capped output. Both descriptors are drained in one `poll` loop, because reading stdout to EOF before touching stderr deadlocks on any child that fills the 64 KiB stderr pipe first.
- **`Subprocess.Child`** — a long-lived child with a stdin write end, chunk callbacks, and an `onExit` that fires **after** reaping, so a handler can trust `isRunning` and `exitCode` together.
- Explicitly `posix_spawn` rather than `fork`/`exec`: no window in which the child shares this process's memory, which matters for a process holding several threads and a lock around its caches.
- `POSIX_SPAWN_SETPGROUP` with pgroup 0, and every kill goes to `-pid`. A helper that forks a descendant — `codex app-server` starting a sandbox, `arkcli` running a subcommand — leaves nothing behind.
- One implementation for both platforms on purpose. `posix_spawn`, `poll`, `waitpid` and `kill` all exist on Darwin; a second implementation behind a conditional would be a second thing to be wrong.

## What the tests can and cannot show

`SubprocessTests` covers bulk output on both streams, a deadline that has to return, a non-zero exit read back exactly, and a streaming child talked to both ways. Two of them are written specifically against the defects above:

- **the group kill is checked from outside**, with `kill(grandchild, 0)` on a pid the grandchild wrote itself — not with a flag `Subprocess` sets for itself, which would pass whether or not anything was killed.
- **the exit is a `waitpid` result**, so `exitCode == 7` cannot be satisfied by a default of 0.

They do not show that a *real* `codex app-server` or `arkcli` behaves. That needs the tools installed and signed in, and remains outstanding.

## The trap worth recording

`argv[0]` was left out of the first version of this file — the arguments went to `posix_spawn` as-is. `/bin/sh` then arrived with `$0` set to `-c` and no command string, read stdin (`/dev/null`), and exited silently. Every one of the ten tests failed on "no output at all", which reads like the pipes being miswired rather than like a missing program name: the children *ran*, they just ran something else.

Current API and call sites: [../linux/subprocess.md](../linux/subprocess.md).
