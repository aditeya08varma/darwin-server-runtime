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

        // C interop layer. Wraps libarchive and Mach kernel headers so Swift
        // code elsewhere in the project can call into them. Starts as an
        // empty placeholder in Stage 0 and gains real bindings in Stages 2 and 4.
        .target(name: "CSystemBridge"),

        // Tarball unpacking and cryptographic signature verification for
        // server image bundles. Built out in Stage 2.
        .target(name: "ImageStore", dependencies: ["RuntimeCore", "CSystemBridge"]),

        // Process isolation backends (Seatbelt sandbox-exec and a POSIX
        // fallback). Built out in Stage 3.
        .target(name: "Isolation", dependencies: ["RuntimeCore"]),

        // Mach kernel metrics sampling and the OpenTelemetry exporter.
        // Built out in Stage 4.
        .target(name: "Telemetry", dependencies: ["RuntimeCore", "CSystemBridge"]),

        // The background daemon executable, darwin-runtimed. Hosts the Unix
        // domain socket server and owns job lifecycle.
        .executableTarget(
            name: "DarwinDaemon",
            dependencies: ["RuntimeCore", "ImageStore", "Isolation", "Telemetry"]
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
        .testTarget(name: "SandboxSecurityTests", dependencies: ["Isolation", "ImageStore"]),
        .testTarget(name: "SoakTests", dependencies: ["Telemetry"])
    ]
)
