# Reusing the panel, rather than rewriting it

The migration assessment proposed a Swift core with a separate GTK4 process
drawing the panel, and said the UI would have to be rewritten. That is true of
the **drawing**. It is not true of the panel, and the difference is worth
4,000 lines.

## What was measured

`Sources/Pulse/Panel` is 5,135 lines in 16 files, and every one of them was
excluded from the Linux build in phase 1 with a `#if canImport(SwiftUI)` guard,
on the reading that they are SwiftUI presentation. Counting the actual symbols
says otherwise:

| | lines | `body` | `some View` | `@State` |
|---|---|---|---|---|
| `BotMarkEngine` | 1,512 | 0 | 0 | 0 |
| `BotMarkMorphs` | 485 | 0 | 0 | 0 |
| `BotMarkParticles` | 469 | 0 | 0 | 0 |
| `BotMarkTint` | 243 | 0 | 0 | 0 |
| `BotMarkData`, `Geometry`, `Config`, `Programme`, and the six pure-Swift files | ~1,000 | 0 | 0 | 0 |
| **`BotMarkView`** | **357** | 1 | 2 | 6 |

3,948 of BotMark's 4,305 lines have no SwiftUI view surface at all. What they
have is arithmetic over points, matrices, paths and colours. Only
`BotMarkView` draws — and it has already done the hard part of specifying how,
because `BotMarkEngine` hands it a **`BotMarkFrame`**:

```swift
struct BotMarkFrame {
    var headPath: CGPath
    var transform: CGAffineTransform
    var opacity: Double
    var eyes: [Eye]                 // path, transform, visible
    var badge: Badge?               // centre, radius
    var shapes: [Shape]             // path, opacity, strokeWidth?
    var backParticles: [Painted]    // path, opacity, solid or gradient
    var frontParticles: [Painted]
    var viewBoxRadius: Double       // 129.5 at rest, in a 0…228.54 space
    var morphAmount: Double
    var facing: Double
}
```

That is a display list, written by upstream, in upstream's own unit space. It is
the boundary the GTK4 renderer implements, and it means the animation is not
reimplemented — it is **fed**.

## What the port actually needed

Four names, and one behaviour. `import Foundation` on Linux already provides
`CGFloat`, `CGPoint`, `CGSize` and `CGRect` — each of those was checked by
compiling it on its own. It does **not** provide `CGAffineTransform`,
`CGVector`, `CGPath` or `CGMutablePath`, and there is no `SwiftUI` to provide
`Color`. `Platform/DrawingCompat.swift` supplies those five, spelled the way
upstream already spells them, so a file that imports `CoreGraphics` on a Mac
finds the same names here and its body needs no edit at all.

The behaviour is colour components. `BotMarkTint` asks a colour for its
luminance and its hue to decide whether a brand colour would disappear into the
disc; SwiftUI cannot answer either, so upstream goes through
`NSColor(colour).usingColorSpace(.sRGB)`. On Linux the colour keeps its own
components, and `ColourReading` is the one place that reaches for them —
through `NSColor` on a Mac, so the three call sites in `BotMarkTint` differ
only in the expression after the `=`.

## What was changed in upstream files

Kept deliberately small, and each one is the kind that merges:

- **Import blocks** in 14 files: `#if canImport(SwiftUI) import SwiftUI #endif`
  and the same for `CoreGraphics` and `AppKit`.
- **`import Foundation`** added to three files that were getting it from
  SwiftUI's re-export (`BotMarkParticles`, `BotMarkProgramme`, `BotMarkTests`).
  Unconditional, because it is harmless on a Mac and an `#else` would not be.
- **Three sites** in `BotMarkTint` where `NSColor(colour).usingColorSpace(.sRGB)`
  became `colour.reading`. The surrounding logic — the luminance floor, the
  amount of white to mix in, the weights — is untouched.
- **Two sites each** in `BotMarkTests` and `BotMarkChoreographyTests` of the same
  substitution, so those assertions run here rather than being skipped.
- **`BotMarkGaze` moved** out of `BotMarkView.swift` into its own file. It is
  an enum, not a view, and it was only in that file because that is where it
  was first needed; the engine and upstream's tests both use it. Nothing was
  renamed.
- **`renderContactSheet`** in `BotMarkChoreographyTests` — an opt-in test that
  lays poses out in a `VStack` and rasterises them with `ImageRenderer` — is
  the one thing left behind a `#if canImport(SwiftUI)`. Every assertion above
  it runs here.

**Still excluded, and correctly:** `BotMarkView.swift` (it draws, and drawing is
what the GTK process does) and `ProviderMarkTests.swift` (it rasterises marks
into an `NSImage` and compares bytes; there is nothing left of it to test
without AppKit).

## The bug upstream's tests caught, which nothing else would have

`CGAffineTransform` composes in a way that is easy to get subtly wrong, and the
first version of `DrawingCompat` got all three helpers wrong — `translatedBy`,
`scaledBy` and `rotated` were each written as `concatenating`, which applies the
new operation in the *destination* space:

| | CoreGraphics | the first version |
|---|---|---|
| `translatedBy` | `tx' = tx + x·a + y·c` | `tx + x` |
| `scaledBy` | scales `a, b, c, d`; `tx`/`ty` untouched | scales `tx`/`ty` too |
| `rotated` | `Concat(R, self)`; `tx`/`ty` untouched | rotates `tx`/`ty` |

The difference is invisible until a transform has both a scale and a
translation — and then it is the whole drawing. Enabling upstream's own
`BotMarkTests` (861 lines, 30 tests) found it immediately: **8,744 of its
assertions failed on a single number**, how far the mark had slid out of the
rail's budget. After the fix, all 30 pass, and so do the choreography and rest
suites.

That is the argument for enabling upstream's tests rather than writing new
ones. A test written alongside the port checks the port against itself, and this
bug was in the shim — the part furthest from anything a port-side test would
question.

**The lesson is recorded in the code too:** this repository's own transform test
had asserted the wrong answers, because it was written from the same
misunderstanding as the shim. It now pins the three CoreGraphics formulas
directly, and says so.

## What the panel costs to run here

`BotMarkChoreographyTests` has a test that calls `boundingBoxOfPath` three times
a frame across 2.16 million frames. Against CoreGraphics' native call that is
nothing; against a Swift reimplementation it was **417 seconds**, because the
first version sampled each segment at 32 points and built an array per call.

It now solves the derivative — a quadratic for a quadratic segment and the
quadratic that a cubic's derivative is — which is both the exact answer and the
fast one, with no allocation in the loop. That cut the suite to 226 seconds.
One test, `aimingKeepsTheEyesInTheFace`, is still ~103 seconds of it.

Two consequences worth knowing:

- **The bound suites are the slowest thing in `swift test` now.** The whole run
  is about five minutes, and most of it is upstream's animation tests.
- **A wall-clock deadline is not a wall-clock guarantee here.** `UsageRefreshTests`
  had an `elapsed < 20 seconds` bound as a proxy for "released by the pass
  ending, not by the deadline", and it started failing at 212 seconds once these
  suites were enabled — with `settled == false` against a 60-second deadline.
  That is not `UsageStore.idle(within:)` misbehaving: its implementation is a
  `Task` that sleeps for the deadline and then gives up, and that task cannot be
  resumed while the cooperative pool has no free thread. Upstream's animation
  tests are minutes of **synchronous** arithmetic inside `async` tests, so they
  hold every thread there is.

  The test now uses a deadline as a hang guard only, and asserts the property
  structurally — a waiter released by the clock wakes with `isRefreshing` still
  true, which no amount of starvation can fake.

  **`pulse --refresh` uses the same `idle(within:)` and the same 180-second
  deadline** (`Usage/UsageRefresh.swift`), and there the timer is dependable,
  for a reason worth stating rather than assuming: that process does nothing
  else. Its work is network and file I/O, which yields, so the pool always has a
  thread to resume the sleep on. The trap this section describes is specifically
  about a *test process* that has put minutes of synchronous arithmetic on the
  same pool — it is not a caveat on the CLI, and writing it as one would have
  been wrong.

The remaining cost has a name and a next step if it ever matters: `copy(using:)`
materialises a transformed command list per call, so a lazily-transformed path
would remove the other half of the allocation. It is not worth doing for a test
suite.

## What is not done

The renderer. `BotMarkView` (357 lines) walks `BotMarkFrame` in this order —
back particles, shapes, head, eyes, front particles, badge — scaling by
`extent / (viewBoxRadius * 2)` from an origin at `viewBoxCentre - viewBoxRadius`.
That order and that arithmetic are the specification for the GTK4 side, and
rewriting it in Cairo is the one genuine piece of UI work left in the panel.
`PanelPlacement.swift` (461 lines) turned out to need nothing: it was never
excluded, because it is edge-placement geometry with two mentions of AppKit in
its comments and no AppKit in its code.
