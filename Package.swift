// swift-tools-version:5.9
// This file describes how the darwin-server-runtime project is put together:
// which modules (targets) exist, how they depend on each other, and which
// external packages we pull in. Every later stage adds real code inside the
// targets listed here rather than changing this structure.
import PackageDescription

let package = Package(
    name: "darwin-server-runtime",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "darwin-run", targets: ["DarwinRuntimeCLI"]),
        .executable(name: "darwin-runtimed", targets: ["DarwinDaemon"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0")
    ],
    targets: [
        // Shared types (IPC messages, config structs, protocols) used by both
        // the daemon and the CLI. Pure Swift, no platform-specific code.
        .target(name: "RuntimeCore"),

        // A systemLibrary target: not code we compile, just a hand-written
        // module map that makes an already-installed external library
        // (Homebrew's libarchive) importable as `import CArchive`. See
        // Sources/CArchive/module.modulemap for why libarchive gets its
        // own dedicated target instead of being folded into CSystemBridge.
        .systemLibrary(name: "CArchive"),

        // C interop layer for our own hand-written C glue code (Mach
        // kernel telemetry bindings, added in Stage 4). Does not wrap
        // libarchive; see CArchive above for that.
        .target(name: "CSystemBridge"),

        // Tarball unpacking and cryptographic signature verification for
        // server image bundles. Depends on CArchive directly for
        // libarchive, since libarchive's C API is called straight from
        // Swift with no wrapper layer in between.
        .target(name: "ImageStore", dependencies: ["RuntimeCore", "CSystemBridge", "CArchive"]),

        // Process isolation backends (Seatbelt sandbox-exec and a POSIX
        // fallback). Built out in Stage 3.
        .target(name: "Isolation", dependencies: ["RuntimeCore"]),

        // Mach kernel metrics sampling and the OpenTelemetry exporter.
        // Built out in Stage 4.
        .target(name: "Telemetry", dependencies: ["RuntimeCore", "CSystemBridge"]),

        // The background daemon executable, darwin-runtimed. Hosts the Unix
        // domain socket server and owns job lifecycle.
        //
        // The -L flag here forces the linker to resolve libarchive against
        // Homebrew's copy in this final binary, rather than falling back
        // to whatever system copy happens to be on the default search
        // path. Without it, this target's headers (from CArchive, pointed
        // at Homebrew's 3.8.9) and its actual linked library (macOS's
        // bundled 3.7.4) would be two different builds of libarchive that
        // happen to agree today, not something guaranteed to keep
        // agreeing. See DEBUGGING_LOG.md for how this was found.
        .executableTarget(
            name: "DarwinDaemon",
            dependencies: ["RuntimeCore", "ImageStore", "Isolation", "Telemetry"],
            linkerSettings: [
                .unsafeFlags(["-L/opt/homebrew/opt/libarchive/lib"])
            ]
        ),

        // The user-facing CLI executable, darwin-run. Talks to the daemon
        // over the socket; never contains isolation or telemetry logic itself.
        .executableTarget(
            name: "DarwinRuntimeCLI",
            dependencies: [
                "RuntimeCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ]
        ),

        .testTarget(name: "RuntimeCoreTests", dependencies: ["RuntimeCore"]),
        // Same -L reasoning as DarwinDaemon above: this test bundle also
        // links ImageStore (and therefore CArchive) into its own final
        // binary, so it needs the same explicit path.
        .testTarget(
            name: "SandboxSecurityTests",
            dependencies: ["Isolation", "ImageStore"],
            linkerSettings: [
                .unsafeFlags(["-L/opt/homebrew/opt/libarchive/lib"])
            ]
        ),
        .testTarget(name: "SoakTests", dependencies: ["Telemetry"])
    ]
)
