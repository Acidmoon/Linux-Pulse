import Foundation

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

#if !canImport(os)

/// `OSAllocatedUnfairLock`, for platforms with no `os` module.
///
/// The real thing is a futex-backed unfair lock with its state allocated
/// alongside it. Neither property matters at these call sites — two of them,
/// both guarding a small value read and written on the main actor plus a
/// database queue — so this is a plain `NSLock` around the state and nothing
/// clever.
///
/// The spelling matches so the call sites do not have to know which platform
/// they are on, including the `uncheckedState:` label: the real type uses it to
/// say the caller promises the state is `Sendable` without the compiler
/// checking, which is a promise this has no way to break.
///
/// `@unchecked Sendable` for the same reason the real type is: the lock is what
/// makes it safe, and the compiler cannot see that from the stored property.
final class OSAllocatedUnfairLock<State>: @unchecked Sendable {
    private let lock = NSLock()
    private var state: State

    init(initialState: State) {
        state = initialState
    }

    init(uncheckedState: State) {
        state = uncheckedState
    }

    // `inout` rather than a plain value, matching the real signature. Callers
    // mutate a struct field through it, which a by-value closure would not
    // allow.
    func withLock<Result>(_ body: (inout State) throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body(&state)
    }

    func withLockUnchecked<Result>(_ body: (inout State) throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body(&state)
    }
}

#endif
