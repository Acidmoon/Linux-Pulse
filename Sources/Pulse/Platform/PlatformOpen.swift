import Foundation

#if canImport(AppKit)
import AppKit
#endif

/// Handing a URL to whatever the desktop uses for it.
///
/// Three call sites needed this: the OAuth flows open the provider's sign-in
/// page, and the Cursor web login opens its own. On macOS that is
/// `NSWorkspace.open`; there is no equivalent in Foundation, and the Linux
/// answer is not a library call but the freedesktop helper.
///
/// `xdg-open` rather than `GAppInfo` because it is the same thing the desktop
/// itself runs, it is present on every freedesktop system including ones with
/// no GLib bindings installed, and it needs no session. It is deliberately
/// *not* awaited: the browser outlives the call, and a sign-in that blocked on
/// `xdg-open` exiting would block until the browser closed.
enum PlatformOpen {
    /// Where `xdg-open` lives, in the order to try it. PATH is searched first
    /// because a distribution is free to put it elsewhere; the literals cover
    /// a GUI process launched with a PATH that does not include it, which is
    /// how an app started from a `.desktop` file can end up.
    private static let xdgOpenCandidates = [
        "/usr/bin/xdg-open",
        "/usr/local/bin/xdg-open",
        "/bin/xdg-open",
    ]

    /// Opens `url`, or reports that it could not. Returning false is not
    /// necessarily fatal to a caller — a sign-in flow can still show the
    /// address for the user to open by hand.
    @discardableResult
    static func url(_ url: URL) -> Bool {
        #if canImport(AppKit)
        return NSWorkspace.shared.open(url)
        #else
        guard let executable = xdgOpen() else { return false }

        let process = Process()
        process.executableURL = executable
        process.arguments = [url.absoluteString]
        // The desktop helper writes diagnostics to stderr; discarding them
        // keeps a broken association rule from spraying the terminal of
        // whatever started Pulse.
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return false
        }
        return true
        #endif
    }

    #if !canImport(AppKit)
    private static func xdgOpen() -> URL? {
        for candidate in xdgOpenCandidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return URL(fileURLWithPath: candidate)
        }
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            for directory in path.split(separator: ":") {
                let candidate = "\(directory)/xdg-open"
                if FileManager.default.isExecutableFile(atPath: candidate) {
                    return URL(fileURLWithPath: candidate)
                }
            }
        }
        return nil
    }
    #endif
}
