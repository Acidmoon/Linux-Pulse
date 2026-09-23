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
        await PulseLinuxMain.run()
    }
}
#endif
