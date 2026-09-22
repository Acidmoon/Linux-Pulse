# Kimi Code

Service: [`KimiCodeUsageService.swift`](../../Sources/Pulse/Providers/KimiCodeUsageService.swift).

Extra accounts are not supported. `keepsLocalTranscripts` is false. No first-run detection: nothing to install, and Pulse does not go looking for a *key*, so it stays off until switched on.

## Credential

Two places it can come from, in this order:

1. **A key pasted into Settings**, kept in `keys.dat`. It wins, for the reason OpenCode Go's does: someone who typed a key meant that one to be used.
2. **A login another tool already holds** — the same borrowing Claude Code, Codex, Grok, Command Code and OpenCode Go get. Two stores are read, and **the freshest usable token wins** rather than one path winning by order:
   - `~/.pi/agent/auth.json` → `kimi-coding.access`, with `expires` in **milliseconds**
   - `~/.kimi-code/credentials/kimi-code.json` → `access_token`, with `expires_at` in **seconds**

   The units differ per store and are declared per store in `loginSources`. Reading one on the other's scale puts the expiry in the year 58691, and an expired token would then be handed over for ever.

**Nothing here refreshes anything, deliberately.** Both stores keep a refresh token beside the access token, and OAuth refresh tokens rotate: spending one would invalidate the copy its owner is holding and sign the user out of Pi or of the CLI. A lapsed token is reported as `kimiLoginExpired` — its own case, because the remedy is to run the owning tool rather than to enter a key — and left alone. `ConnectionRemedy` offers `kimi` for it.

The endpoint takes **either** credential as a bearer token, which is why one route serves both.

## Route

`GET https://api.kimi.com/coding/v1/usages` with a bearer token.

The service comments this as Kimi’s **documented** usage endpoint, unlike most of the undocumented account routes elsewhere. That is not a Pulse official-integration claim, and the JSON can still change.

## Two kinds of limit, not the same figure

- `limits[]` — windows the service actually times, each stating a `duration` and a `timeUnit`. Read as given. An unrecognised unit **drops that entry** rather than being guessed at.
- `usage` — the weekly allowance. The reply gives a reset time and **no length**. Because the window rolls, the reset lands anywhere inside the week and says nothing about how long it runs. Seconds sort it after the shorter windows (`reportsLength: false`) and are never displayed. The window clock and forecast must not divide by that number.

Every count arrives as a **string**. `limits[].detail` reports what is *left* with no `used` field, so spend is `limit - remaining` there and `used` where that is given.

`membership.level` is the plan, tidied from `LEVEL_INTERMEDIATE` to “Intermediate”, passed through when unfamiliar. `parallel.limit` is how many requests may run at once, not a balance. `totalQuota` comes back empty. Neither becomes `creditBalance`.
