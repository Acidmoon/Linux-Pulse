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
enum PulseLinuxMain {
    /// `async` for `--refresh` alone, which has to await a pass. It cannot
    /// block on one instead: `UsageStore` is main-actor bound, so a semaphore
    /// held on this thread would stop the very work it was waiting for. The
    /// other modes are synchronous and run before the first suspension, so
    /// nothing about the status line's path changed.
    @MainActor
    static func run() async -> Int32 {
        // Before anything can write to a child. A helper exiting closes its
        // end of a pipe, and the write Pulse does next would kill it — macOS
        // does this in `AppDelegate`, which is not built here.
        Subprocess.ignoreSIGPIPE()

        if CommandLine.arguments.contains(StatusLineHook.modeArgument) {
            StatusLineHook.runAsStatusLine()
            return 0
        }

        if CommandLine.arguments.contains("--install-statusline") {
            print(StatusLineHook.install() ? "installed" : "failed")
            return StatusLineHook.install() ? 0 : 1
        }

        if CommandLine.arguments.contains("--uninstall-statusline") {
            print(StatusLineHook.uninstall() ? "uninstalled" : "failed")
            return StatusLineHook.uninstall() ? 0 : 1
        }

        if CommandLine.arguments.contains(UsageReport.modeArgument) {
            return UsageReport.run()
        }

        // After `--json`, because the two are usually run together and the one
        // that reads should not have to wait behind the one that fetches.
        if CommandLine.arguments.contains(UsageRefresh.modeArgument) {
            return await UsageRefresh.run()
        }

        // Before `LegacyDefaults.migrateIfNeeded()`, like the others: these are
        // commands, not a launch, and the one thing they must not do is decide
        // an installation's defaults on the way past.
        for argument in [KeyCommand.setArgument, KeyCommand.clearArgument]
        where CommandLine.arguments.contains(argument) {
            return KeyCommand.run(argument: argument)
        }

        LegacyDefaults.migrateIfNeeded()

        // Launched with no arguments, which is what a person does after
        // installing — so this is where the panel belongs. It is a separate
        // binary, and this **replaces the process rather than waiting on a
        // child**: `pulse` in a terminal should put the rail on screen and
        // return the prompt, exactly as the Mac app does when it is opened.
        //
        // Not found means the panel was not built — a machine with no GTK4, or
        // a headless install — and that is not an error worth a stack of
        // output. It falls through to the usage text, which names it.
        if let panel = Self.siblingPanel(), launch(panel) {
            return 0
        }

        FileHandle.standardError.write(Data(usage.utf8))
        return 2
    }

    /// The panel executable beside this one, if it was built.
    ///
    /// Beside, not on `PATH`: the two are installed together by
    /// `Scripts/install.sh`, and finding a *different* Pulse on `PATH` would be
    /// worse than finding none.
    private static func siblingPanel() -> String? {
        let selfPath = CommandLine.arguments.first ?? ""
        let directory = (selfPath as NSString).deletingLastPathComponent
        guard !directory.isEmpty else { return nil }
        let candidate = (directory as NSString).appendingPathComponent("PulsePanel")
        return FileManager.default.isExecutableFile(atPath: candidate) ? candidate : nil
    }

    /// `execv`, so the panel inherits this terminal and this process becomes
    /// it. Returns false when the kernel refuses, in which case the caller says
    /// so rather than leaving nothing on screen.
    private static func launch(_ path: String) -> Bool {
        #if canImport(Glibc)
        var arguments: [UnsafeMutablePointer<CChar>?] = [strdup(path), nil]
        defer { arguments.forEach { free($0) } }
        execv(path, &arguments)
        return false
        #else
        return false
        #endif
    }

    private static var usage: String {
        """
        Pulse — usage monitor for the AI coding tools you already have.

        Run with no arguments to open the floating panel, where one is
        installed. It is a separate binary — this one links no GUI libraries at
        all, so everything below works over ssh and in a container. Available:

          --json                 print the last readings, one account each
          --refresh              ask every enabled provider once, then exit
          --set-key <provider>   read a key from stdin and store it, sealed
          --clear-key <provider> remove a stored key
          --statusline           Claude Code status line mode (reads stdin)
          --install-statusline   register this binary as Claude Code's status line
          --uninstall-statusline undo that

        \(UsageRefresh.modeArgument) fills the cache and \(UsageReport.modeArgument) reads it. Both
        work with no display; \(UsageReport.modeArgument) on its own never fetches, so
        the figures it prints are as old as the last \(UsageRefresh.modeArgument).

        \(KeyCommand.setArgument) takes its key on stdin, never as an argument, so it
        does not reach `ps` or your shell history.

        """
    }
}

#endif
