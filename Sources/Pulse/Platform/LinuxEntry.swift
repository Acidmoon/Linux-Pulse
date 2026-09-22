#if !canImport(AppKit)
import Foundation

/// The Linux entry point.
///
/// macOS dispatches from `PulseMain` in `App/PulseApp.swift`. That file is
/// excluded here because it goes on to start SwiftUI, but the dispatch it does
/// first is not platform-specific at all — it is argument matching, and it
/// exists because Claude Code runs this same binary as its status line command,
/// so that case has to be settled before any of the app starts.
///
/// So the same arguments are handled here, in the same order and for the same
/// reasons. What is missing is the last step: where macOS calls
/// `PulseApp.main()` and opens a panel, this prints what the build can do. The
/// floating panel is a separate GTK4 process (roadmap phase 2), not something
/// this binary starts.
///
/// The ordering below is copied deliberately rather than re-derived:
///
/// - The status line runs first because a terminal redraw must never wait on
///   settings being read.
/// - `--install-statusline` and `--uninstall-statusline` print and exit,
///   because what they write into Claude Code's settings is this binary's own
///   path.
/// - `--json` runs **before** `LegacyDefaults.migrateIfNeeded()` on purpose:
///   something that runs every couple of seconds must not be the thing that
///   decides an installation's defaults.
@main
enum PulseLinuxMain {
    /// `async` for `--refresh` alone, which has to await a pass. It cannot
    /// block on one instead: `UsageStore` is main-actor bound, so a semaphore
    /// held on this thread would stop the very work it was waiting for. The
    /// other modes are synchronous and run before the first suspension, so
    /// nothing about the status line's path changed.
    static func main() async {
        // Before anything can write to a child. A helper exiting closes its
        // end of a pipe, and the write Pulse does next would kill it — macOS
        // does this in `AppDelegate`, which is not built here.
        Subprocess.ignoreSIGPIPE()

        if CommandLine.arguments.contains(StatusLineHook.modeArgument) {
            StatusLineHook.runAsStatusLine()
            exit(0)
        }

        if CommandLine.arguments.contains("--install-statusline") {
            print(StatusLineHook.install() ? "installed" : "failed")
            exit(0)
        }

        if CommandLine.arguments.contains("--uninstall-statusline") {
            print(StatusLineHook.uninstall() ? "uninstalled" : "failed")
            exit(0)
        }

        if CommandLine.arguments.contains(UsageReport.modeArgument) {
            exit(UsageReport.run())
        }

        // After `--json`, because the two are usually run together and the one
        // that reads should not have to wait behind the one that fetches.
        if CommandLine.arguments.contains(UsageRefresh.modeArgument) {
            exit(await UsageRefresh.run())
        }

        LegacyDefaults.migrateIfNeeded()

        // No panel to open yet, so say so rather than exiting silently. A
        // command that starts nothing and reports nothing reads as broken.
        FileHandle.standardError.write(Data(usage.utf8))
        exit(2)
    }

    private static var usage: String {
        """
        Pulse — usage monitor for the AI coding tools you already have.

        The Linux floating panel is not built yet; this binary is the headless
        core it will read from. Available now:

          --json                 print the last readings, one account each
          --refresh              ask every enabled provider once, then exit
          --statusline           Claude Code status line mode (reads stdin)
          --install-statusline   register this binary as Claude Code's status line
          --uninstall-statusline undo that

        \(UsageRefresh.modeArgument) fills the cache and \(UsageReport.modeArgument) reads it. Both
        work with no display; \(UsageReport.modeArgument) on its own never fetches, so
        the figures it prints are as old as the last \(UsageRefresh.modeArgument).

        """
    }
}

#endif
