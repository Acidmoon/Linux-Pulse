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

        // **Before anything else that could start the panel.** `pulse --help`
        // used to reach the end of this and open the rail, which is a strange
        // answer to a question about the command line — and it made the usage
        // text unreachable on a machine where the panel is installed, which is
        // every machine that has one.
        if CommandLine.arguments.contains("--help") || CommandLine.arguments.contains("-h") {
            print(usage)
            return 0
        }

        if CommandLine.arguments.contains(UsageReport.modeArgument) {
            return UsageReport.run()
        }

        // What is on the rail, and what is not — the question somebody running
        // `--enable` is really asking is *why is that ring empty?*, so the list
        // says which are switched off rather than only which are on.
        if CommandLine.arguments.contains("--providers") {
            print(ProviderCommand.list())
            return 0
        }

        // Which providers the rail shows, which had no command at all.
        //
        // **The presence of the argument is checked here, not inside.** The
        // first version looped over the two names and called `run(argument:)`
        // with each — which matched its own name every time and ran, so
        // `--providers` reported "--enable needs a provider name".
        for argument in [ProviderCommand.enableArgument, ProviderCommand.disableArgument]
        where CommandLine.arguments.contains(argument) {
            if let code = ProviderCommand.run(argument: argument) { return code }
        }

        // The panel's own settings, and how to stop it.
        for argument in PanelCommand.arguments where CommandLine.arguments.contains(argument) {
            if let code = PanelCommand.run(argument: argument) { return code }
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

        // **Said, rather than a bare usage dump.** The usage text is the same
        // wall of options whoever is reading it, and it does not contain the
        // one fact that matters here: this build has no panel. Reached most
        // often by somebody who built the command line alone — `swift build
        // --product Pulse` on a machine without GTK4 — and then typed `pulse`.
        if CommandLine.arguments.count == 1 {
            FileHandle.standardError.write(Data("""
            Pulse: no panel is installed beside this command, so there is \
            nothing to open.

              \\(LinuxLoginItem.fileURL.path) is not there either, so nothing \
            will start one at login.

            The command line does not need the panel. Try `pulse --help`, or \
            `pulse --json` for the last readings.
            """.utf8))
            return 2
        }

        FileHandle.standardError.write(Data(usage.utf8))
        return 2
    }

    /// The panel executable that belongs to this command.
    ///
    /// Not from `PATH`: finding a *different* Pulse's panel would be worse than
    /// finding none. The two places it can be are in `LinuxLoginItem`, which
    /// works out the same path for the autostart entry — **one implementation,
    /// because there were two and they disagreed.** This one knew only about a
    /// panel *beside* the command, and `Scripts/linux/install.sh` puts the
    /// command in `$prefix/bin` as a symlink and everything else in
    /// `$prefix/lib/pulse` — so an installed `pulse` with no arguments found no
    /// panel, printed the usage text, and left a reader looking at a list of
    /// options instead of at the thing they asked for.
    private static func siblingPanel() -> String? { LinuxLoginItem.panelExecutable }

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

        The rail:

          \(ProviderCommand.enableArgument) <provider>    show it on the rail
          \(ProviderCommand.disableArgument) <provider>   take it off
          --providers            what is on the rail, and what is not

        The panel itself. These take effect immediately on a panel that is
        already running, so nothing has to be killed and restarted:

        \(PanelCommand.usageLines)

          --help                 this

        \(UsageRefresh.modeArgument) fills the cache and \(UsageReport.modeArgument) reads it. Both
        work with no display; \(UsageReport.modeArgument) on its own never fetches, so
        the figures it prints are as old as the last \(UsageRefresh.modeArgument).

        \(KeyCommand.setArgument) takes its key on stdin, never as an argument, so it
        does not reach `ps` or your shell history.

        """
    }
}

#endif
