#if !canImport(ObjectiveC)

/// `autoreleasepool`, for platforms that have no autorelease pool.
///
/// On Darwin this drains an autorelease pool around `body`, which is what
/// bounds the lifetime of the temporaries a loop body creates. There is no
/// such thing on Linux, and every call site in Pulse uses it for exactly that
/// — bounding temporary allocations inside a per-line or per-row loop, never
/// to defer a side effect — so running the body directly is the correct
/// translation rather than a shortcut.
///
/// The signature matches the Darwin one so a call site does not have to know
/// which platform it is on.
///
/// Guarded on `canImport(ObjectiveC)` rather than on `os(Linux)` because the
/// pool is an Objective-C runtime feature: any platform with the runtime has
/// it, and any platform without one does not.
@inline(__always)
func autoreleasepool<Result>(invoking body: () throws -> Result) rethrows -> Result {
    try body()
}

#endif
