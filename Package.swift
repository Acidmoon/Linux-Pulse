// swift-tools-version: 6.0

import PackageDescription

// The manifest is evaluated by the host's toolchain, so `#if os(macOS)` here
// picks the dependency set for the platform being built on rather than for
// the platform being targeted.
//
// Linux differs from macOS in exactly three ways, and they are all in this
// file:
//
//   1. Sparkle does not build on Linux. It is a macOS updater and the Linux
//      port removes updating entirely (system package manager or a manual
//      download from GitHub Releases). Dropping the dependency rather than
//      excluding its import sites means SwiftPM never tries to resolve it.
//   2. CryptoKit does not exist on Linux. swift-crypto is Apple's own
//      cross-platform implementation of the same API surface; on Linux it
//      provides a module named `Crypto` covering everything Pulse uses
//      (AES.GCM, SHA256, SymmetricKey). Sources import it as
//      `#if canImport(CryptoKit) import CryptoKit #else import Crypto #endif`.
//   3. `import SQLite3` works on Darwin but not on Linux. The Linux toolchain
//      ships no modulemap for SQLite, so CSQLite below supplies one against
//      the system library.
//
// Everything else — the platforms list, the linker settings, the single
// executable target and its Swift 6 language mode — is the macOS build as it
// was. See Docs/linux/migration-assessment.md.

#if os(macOS)
let platformDependencies: [Package.Dependency] = [
    // In-place updates. Sparkle needs its framework embedded in the app
    // bundle, which Scripts/bundle.sh does — a bare `swift run` build
    // links against it but has nowhere to put it, so the updater is
    // inert there. See AppUpdate.swift.
    .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")
]

let pulseDependencies: [Target.Dependency] = [
    .product(name: "Sparkle", package: "Sparkle"),
    "CSQLite"
]

let pulseLinkerSettings: [LinkerSetting] = [
    // macOS picks which control design to draw from the SDK
    // version recorded in LC_BUILD_VERSION, not from the version
    // it is running on. Below 26 it draws the pre-Tahoe controls,
    // and no Info.plist key opts back in.
    //
    // SwiftPM records the wrong thing here: given `.macOS(.v14)`
    // above it stamps that **deployment target** into the SDK
    // field, so every build — `swift run`, `swift build`, and
    // running the package from Xcode — comes out drawn the old
    // way. Measured 2026-09-20: 14.0 draws the old controls, 26.5
    // and 27.0 both draw the current ones.
    //
    // 26.0 is the floor this app already requires (`glassEffect`
    // needs that SDK to compile at all), stated as a floor rather
    // than as whichever SDK happens to be installed, because a
    // manifest cannot ask the toolchain. Scripts/bundle.sh stamps
    // the real SDK over this for releases and then reads the
    // result back off every slice.
    .unsafeFlags(["-Xlinker", "-platform_version",
                  "-Xlinker", "macos",
                  "-Xlinker", "14.0",
                  "-Xlinker", "26.0"])
]

// See the Linux branch below for why these are hoisted.
let cSQLitePkgConfig: String? = nil
let cSQLiteProviders: [SystemPackageProvider] = []
#else
let platformDependencies: [Package.Dependency] = [
    .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"4.0.0")
]

let pulseDependencies: [Target.Dependency] = [
    .product(name: "Crypto", package: "swift-crypto"),
    "CSQLite"
]

// No SDK-stamp equivalent is needed: nothing on Linux chooses a control
// design from a recorded SDK version.
let pulseLinkerSettings: [LinkerSetting] = []

// Hoisted out of the target declaration: `#if` cannot stand inside an
// argument list, and SwiftPM needs these to be nil/empty on Darwin so that a
// host without pkg-config is not asked for one.
// `SystemPackageProvider` offers apt/brew/yum, not dnf. apt is the one that
// matches the distribution the Linux port is verified against; RPM users
// install sqlite-devel by hand.
let cSQLitePkgConfig: String? = "sqlite3"
let cSQLiteProviders: [SystemPackageProvider] = [
    .apt(["libsqlite3-dev"]), .yum(["sqlite-devel"])
]
#endif
let package = Package(
    name: "Pulse",
    // Required for the localized resources in Sources/Pulse/Resources/*.lproj.
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Pulse", targets: ["Pulse"])
    ],
    dependencies: platformDependencies,
    targets: [
        // Supplied on both platforms rather than only on Linux, so that
        // Sources/CSQLite is never a directory no target claims — SwiftPM
        // warns about those. The macOS SDK has sqlite3.h too, so the module
        // builds there as well; sources prefer the system `SQLite3` module
        // whenever `canImport` says it is there.
        .systemLibrary(
            name: "CSQLite",
            path: "Sources/CSQLite",
            pkgConfig: cSQLitePkgConfig,
            providers: cSQLiteProviders
        ),
        .executableTarget(
            name: "Pulse",
            dependencies: pulseDependencies,
            path: "Sources/Pulse",
            resources: [
                .process("Resources")
            ],
            linkerSettings: pulseLinkerSettings
        ),
        // Tests the executable target directly rather than through a library
        // split. Pulse is one app, not a framework with an app on top, and
        // carving sixty-nine files into two targets to make them reachable would be a
        // refactor in service of the test runner. SwiftPM has been able to
        // `@testable import` an executable target since Swift 5.5.
        .testTarget(
            name: "PulseTests",
            dependencies: ["Pulse"],
            path: "Tests/PulseTests",
            // Captured provider replies, kept as the files they arrived as so
            // a diff against a changed schema is readable.
            resources: [
                .copy("Fixtures")
            ]
        )
    ]
)
