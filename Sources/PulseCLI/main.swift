// The command-line half of Pulse, and nothing else.
//
// **Three lines, because the module it calls is a library now.** See
// `Pulse.PulseCLI` for why the split exists. The binary is still called
// `Pulse` — the product name is what names it, not the target — so every
// script and every document that says `pulse --json` is still right.
//
// It links no GTK. That is the point of the split: `pulse --json` runs on a
// machine with no GUI libraries installed, and the panel — which needs GTK4,
// layer-shell and X11 — is a different executable that only exists where those
// are.

import Foundation
import Pulse
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

exit(await PulseCLI.run())
