// swift-tools-version: 6.0

import PackageDescription
import Foundation

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

// There is no GTK on a Mac and the macOS panel is the SwiftUI one, so the
// panel's targets do not exist here at all rather than being excluded later.
let panelTargets: [Target] = []
let panelProducts: [Product] = []
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

// The Linux panel's three C surfaces, each its own target because each is a
// separate optional dependency and the panel has to be able to run without two
// of them:
//
//   - CGTK4 is the window, the widgets and the CSS.
//   - CGTK4LayerShell is the Wayland protocol for edge-docked windows. A
//     machine without it builds and runs the panel on X11; nothing else
//     changes, because the panel asks `pulse_layer_shell_supported()` at
//     runtime and only Wayland ever says yes.
//   - CX11 is the same "always on top" answer for X11, which GTK4 has no API
//     for and layer-shell does not cover.
//
// They are `systemLibrary` targets rather than C targets with sources: every
// helper in them is a cast or a macro wrapper, which the compiler can inline,
// and a C target would be a second build system to keep working for no library
// of its own. See Sources/CGTK4/pulse-gtk.h.
//
// `SystemPackageProvider` has no `.dnf`; apt is the distribution the port is
// verified against and RPM users install these by hand (Docs/linux/install.md).
//
// **The panel's targets only exist where GTK4 does**, which is checked here
// rather than left to fail at compile time. `swift test` builds every target in
// the package, so an unconditional `PulsePanel` would mean the *core* could no
// longer be built or tested on a machine without GTK4's headers — and this port
// has a headless half that has to keep working on exactly such a machine. A
// package whose manifest cannot express that is a package that cannot be tested
// on a server.
//
// The check looks for the `.pc` files on the paths pkg-config will search,
// rather than running pkg-config: SwiftPM evaluates this manifest inside a
// sandbox that may not permit it, and a manifest that fails to evaluate is a
// build that fails for a reason nobody can read.
func pkgConfigHas(_ module: String) -> Bool {
    let environment = ProcessInfo.processInfo.environment["PKG_CONFIG_PATH"] ?? ""
    let searchPaths = environment.split(separator: ":").map(String.init) + [
        "/usr/lib/x86_64-linux-gnu/pkgconfig", "/usr/lib/aarch64-linux-gnu/pkgconfig",
        "/usr/lib/pkgconfig", "/usr/share/pkgconfig",
        "/usr/local/lib/pkgconfig", "/usr/local/share/pkgconfig",
    ]
    return searchPaths.contains { FileManager.default.fileExists(atPath: $0 + "/" + module + ".pc") }
}

let panelTargets: [Target] = !pkgConfigHas("gtk4") ? [] : [
    .systemLibrary(
        name: "CGTK4",
        path: "Sources/CGTK4",
        pkgConfig: "gtk4",
        providers: [.apt(["libgtk-4-dev"])]
    ),
    .systemLibrary(
        name: "CGTK4LayerShell",
        path: "Sources/CGTK4LayerShell",
        pkgConfig: "gtk4-layer-shell-0",
        providers: [.apt(["libgtk4-layer-shell-dev"])]
    ),
    .systemLibrary(
        name: "CX11",
        path: "Sources/CX11",
        pkgConfig: "x11",
        providers: [.apt(["libx11-dev"])]
    ),
    .executableTarget(
        name: "PulsePanel",
        dependencies: ["Pulse", "CGTK4", "CGTK4LayerShell", "CX11"],
        path: "Sources/PulsePanel"
    )
]
let panelProducts: [Product] = panelTargets.isEmpty ? [] : [
    .executable(name: "PulsePanel", targets: ["PulsePanel"])
]
#endif
let package = Package(
    name: "Pulse",
    // Required for the localized resources in Sources/Pulse/Resources/*.lproj.
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14)
    ],
    // The floating panel is a separate executable rather than a mode of
    // `Pulse` because it is the one thing here that links GTK4, and
    // `pulse --json` has to keep working on a machine with no GUI libraries at
    // all — a link-time dependency would take that away.
    products: [
        .executable(name: "Pulse", targets: ["Pulse"])
    ] + panelProducts,
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
    ] + panelTargets
)
