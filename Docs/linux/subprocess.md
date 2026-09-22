# Subprocess

How Pulse runs other programs, and why it does not use Foundation's `Process`.
The measurements behind that decision, and what each one does and does not
prove, are in [../decisions/linux-subprocess.md](../decisions/linux-subprocess.md).

Source: [`Sources/Pulse/Platform/Subprocess.swift`](../../Sources/Pulse/Platform/Subprocess.swift).

## The two shapes

### `Subprocess.run` — runs and finishes

```swift
let outcome = try Subprocess.run(
    executable, arguments,
    environment: NetworkSession.subprocessEnvironment(),   // nil inherits
    deadline: 20,
    outputCeiling: 512 * 1024
)

outcome.standardOutput   // Data, capped
outcome.standardError    // Data, capped
outcome.exitCode         // -1 when a signal ended it
outcome.signal           // nil when it exited on its own
outcome.timedOut         // true when the deadline killed it
outcome.succeeded        // no signal, code 0, not timed out
```

Throwing is reserved for **not being able to start**: a pipe that cannot be
created, or a `posix_spawn` that failed. A child that starts and then exits
non-zero is a normal `Outcome`, because every caller reports that differently
and none of them treats it as a programming error.

`environment: nil` inherits Pulse's own environment. A caller that passes one
gives the child exactly that and nothing else — there is no merging.

A deadline is not a failure of the tool, so it is `timedOut` rather than a
throw, and the output read before the deadline is kept. That is the point of
capping rather than discarding: a slow answer is still an answer.

### `Subprocess.Child` — stays alive and is talked to

```swift
let child = try Subprocess.Child(executable: url, arguments: [...])
child.onOutput = { chunk in ... }       // reader thread
child.onErrorOutput = { chunk in ... }  // reader thread, optional
child.onExit = { status in ... }        // after reaping AND draining
child.onOutputClosed = { ... }          // stdout EOF, which is not an exit
child.start()                           // callbacks must be set first
child.write(Data("...\n".utf8))
child.terminate()                       // SIGTERM, grace, SIGKILL, reap
child.isRunning
child.exitCode                          // nil until reaped
```

**Set the callbacks before `start()`.** A chunk that arrives before there is
anywhere to put it is gone, and the child has already been asked to begin.

`onExit` fires **after** `waitpid` has returned **and both reader threads have
finished**. That ordering is the whole reason this type exists: on the
`Process` path a dead child could report `isRunning == true` indefinitely.

Waiting for the readers is part of it, not tidiness. A child that answers a
request and then exits — which is ordinary — leaves its answer in the pipe
buffer, and a callback that fired on the exit alone had the handler discard an
answer that had already arrived. `RPCRequestLifecycleTests` caught exactly
that: the reply to the handshake was thrown away and the next request reported
`.startFailed`.

`onOutputClosed` is a separate callback because **EOF is not an exit**: a
helper can close its stdout and carry on running. Both `CodexAppServer` and
`KiroACPClient` have to act on that — a helper with nothing left to say must
not stay resident with nobody able to kill it — and folding the two events
into one would make that indistinguishable from a clean exit.

## `SIGPIPE` has to be ignored first

Writing to a pipe whose far end has closed raises `SIGPIPE`, and its default
action is to **terminate the process** — so a helper exiting would take Pulse
down with it, which from the outside is an app crashing at random. macOS does
this in `AppDelegate`, which the Linux build excludes, so the call lives in
`Subprocess.ignoreSIGPIPE()` and is made once from `LinuxEntry.main()`. It is
process-wide because the disposition is; there is nothing per-child about it.

## What is guaranteed

- **Both pipes are drained concurrently**, each capped at `outputCeiling`.
  Reading one to EOF before touching the other deadlocks on any child that
  fills the 64 KiB pipe it is not being read from.
- **The child leads its own process group** (`POSIX_SPAWN_SETPGROUP`, pgroup
  0), and every kill goes to `-pid`. A helper that forks a descendant leaves
  nothing behind.
- **Nothing is parked past the call.** `poll` with a 200 ms slice rather than a
  blocking read, so a write end a grandchild is holding open cannot hold a
  thread after the deadline.
- **`SIGTERM`, then `SIGKILL` after `graceAfterTerminate` (2 s).** `terminate()`
  alone is a request, and a tool with a stuck shutdown path is the case this
  exists for.

## What is not

- No `workingDirectory`. Nothing needs it; adding it means an
  `addchdir_np`/`posix_spawn_file_actions_addchdir_np` availability split.
- No shell. A command string has to go through `/bin/sh -c` explicitly, which
  is what the callers that need one do.
- No terminal. stdin is `/dev/null` unless the child is a `Child`, in which
  case it is the write end of a pipe. A tool that prompts gets EOF rather than
  hanging on a terminal that is not there.

## Call sites

| Caller | Shape | Why |
|---|---|---|
| [`Providers/VolcengineUsageService`](../../Sources/Pulse/Providers/VolcengineUsageService.swift) | `run` | `arkcli usage plan --format json`, with a deadline |
| [`Providers/AntigravityUsageService`](../../Sources/Pulse/Providers/AntigravityUsageService.swift) | `run` | probing a loopback port for the language server |
| [`App/StatusLineHook`](../../Sources/Pulse/App/StatusLineHook.swift) | `run` | running the status line Pulse took over from |
| [`Providers/CodexAppServer`](../../Sources/Pulse/Providers/CodexAppServer.swift) | `Child` | JSON-RPC over stdin/stdout for the life of the app |
| [`Providers/KiroACPClient`](../../Sources/Pulse/Providers/KiroACPClient.swift) | `Child` | the same shape for ACP |

`Platform/PlatformOpen` still uses `Process` for `xdg-open`. That is
deliberately left alone: it is fire-and-forget and never asks whether the child
exited, so none of the defects above are reachable from it. Replacing it would
be churn.

[`Provider/ClaudeCodeUsageService.readKeychainCredentials`](../../Sources/Pulse/Providers/ClaudeCodeUsageService.swift)
is guarded rather than ported: it runs `/usr/bin/security`, which is a macOS
binary. On Linux the CLI's credentials are read from
`~/.claude/.credentials.json` by the route beside it.
