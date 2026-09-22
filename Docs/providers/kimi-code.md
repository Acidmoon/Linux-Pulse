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

## Three windows, in two shapes

Measured against a real account on **2026-09-23**. The reply has changed since
this page was first written: the field that carried the rolling allowance was
`usage`, singular, and it is now `usages`, plural, keyed by name — a different
shape, not a rename. Both are read.

- **`limits[]`** — windows the service times, each stating a `duration` and a
  `timeUnit`. Read as given. An unrecognised unit **drops that entry** rather
  than being guessed at. On the captured account this was the five-hour window,
  with real counts (`limit` / `used` / `remaining`).
- **`usages`** — a map of window name to `{ used_ratio, reset_time }`. The ratio
  is already a fraction, so nothing is inferred and `estimated` is false. Three
  keys arrived: `limit_5h`, `limit_month_total`, `limit_month_code`. The
  **lengths are a table in `ratioWindows`, not a parse of the name** — a
  calendar month is not a number of seconds, and turning these names into
  durations would be guessing at a vocabulary that has already changed once. An
  unlisted key is dropped.
- **`usage`** (singular) — the older rolling allowance, still read so a plan
  that receives it does not regress. No length is stated; the seconds sort it
  after the shorter windows.

`limit_5h` states the same window `limits[]` already stated, once as counts and
once as a ratio. A window whose **length** is already accounted for is skipped,
so the five-hour limit is drawn once — and the skip is deliberately not applied
between the two monthly entries, which share one sort key and are told apart by
their ids.

**What `month_total` and `month_code` mean is not stated anywhere in the reply.**
They are not product names, and the card shows the service's own vocabulary
(`scope: "month_total"`) rather than one invented for it. Whether the two are
independent budgets — in which case both belong on the card — or a total and its
part — in which case showing both double-counts — is **unanswered and needs
someone who knows the plan.** The ring takes the fullest of whatever is there,
which on the captured account was `limit_month_total` at 10% where the five-hour
window was at 2%.

`booster_wallet` arrived with the same reply and is **not read**. It is a top-up
balance — `STATUS_DISABLED` on the captured account, priced in CNY, with a
`balance`, a `topupLimit` and a `monthlyChargeLimit` — so it is not an
allowance and must not become a percentage. Recorded rather than omitted: the
field is new, and the next reply may put something in it that does matter.

Every count arrives as a **string**. `limits[].detail` reports what is *left* with no `used` field, so spend is `limit - remaining` there and `used` where that is given.

`membership.level` is the plan, tidied from `LEVEL_INTERMEDIATE` to “Intermediate”, passed through when unfamiliar. `parallel.limit` is how many requests may run at once, not a balance. `totalQuota` comes back empty. Neither becomes `creditBalance`.
