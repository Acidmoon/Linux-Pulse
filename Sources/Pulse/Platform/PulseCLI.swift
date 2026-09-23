#if !canImport(AppKit)
import Foundation

/// The one symbol the command-line executable can see.
///
/// **`public` and alone, deliberately.** The CLI used to be this module: one
/// executable target holding both the dispatch and the four thousand files it
/// dispatches into. It cannot be, because the panel has to import those files,
/// and SwiftPM hands a dependent target an **empty module** when the dependency
/// is an executable — measured, not assumed: a `public func` on the executable
/// side is not visible from the panel, which is why this split exists at all.
///
/// So the module is a library and the CLI is three lines that call this. A
/// `public` symbol would normally mean "API", and this is not: it is the single
/// door the executable needs, and everything behind it stays internal. The
/// panel's door is `PanelModel` and `PanelCanvas`, which are `package` — visible
/// to the rest of this package and to nothing else.
public enum PulseCLI {
    /// Runs the command line. Returns a process exit code.
    @MainActor
    public static func run() async -> Int32 {
        let code = await PulseLinuxMain.run()
        // **Flushed here because swift-corelibs-foundation does not flush on
        // its own.** `UserDefaults` on Linux writes to its in-memory store and
        // reaches the file later — on a timer, or at exit — and these commands
        // *are* the process: `pulse --enable kimiCode` reported "Kimi Code on —
        // 2 on the rail" and the very next command read a file that still said
        // one. The write was in a store that died with the process.
        //
        // At the single exit rather than at each call site, so a command added
        // later cannot forget it. The panel does not need this: it is a
        // long-lived process, and its writes are flushed by the same timer that
        // dropped them here.
        PulseDefaults.shared.synchronize()
        return code
    }
}
#endif
