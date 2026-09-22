import Foundation

/// One line to stderr about a failure that would otherwise be anonymous.
///
/// **Not a logging framework, and deliberately not reaching for one.** Two
/// provider helpers now collapse several distinct failures into a single
/// `Failure.startFailed`, because that is the shape their callers and the tests
/// already agree on and changing it would churn both. The cost of that shape is
/// that a failure with no message is unactionable — seen once on CI, not
/// reproducible locally, and the underlying `posix_spawn` error was the only
/// thing that could have said which of the four it was.
///
/// So the reason goes to stderr and the type stays as it is. Nothing here is
/// buffered, collected or shown in the UI: on a headless run stderr is where a
/// person is already looking, and in the app it goes to the terminal that
/// started it, if any.
enum Diagnostic {
    static func note(_ what: String, _ error: Error?) {
        let detail = error.map { ": \($0)" } ?? ""
        let line = "Pulse: \(what)\(detail)\n"
        FileHandle.standardError.write(Data(line.utf8))
    }
}
