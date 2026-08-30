// Entry point for darwin-run, the user-facing command line client. Each
// subcommand below builds one IPCMessage, sends it through SocketClient,
// and prints a human-readable version of whatever IPCResponse comes back.
import ArgumentParser
import Foundation
import RuntimeCore

/// The top-level darwin-run command. Carries no logic of its own; it only
/// declares which subcommands exist and dispatches to whichever one the
/// user invoked. It conforms to AsyncParsableCommand, not the plain
/// ParsableCommand, because its subcommands need to await network I/O,
/// and swift-argument-parser requires every command from the root down to
/// be async if any of them are.
@main
struct DarwinRun: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "darwin-run",
        abstract: "Client for the darwin-server-runtime daemon.",
        subcommands: [Ping.self, Pull.self, Exec.self, Stop.self, Status.self, Stats.self]
    )
}

/// Checks whether darwin-runtimed is alive and listening on its socket.
struct Ping: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Checks whether darwin-runtimed is alive and listening."
    )

    /// Sends an IPCMessage.ping and prints "pong" if the daemon replied
    /// correctly, or a clear error if it did not respond the way expected.
    func run() async throws {
        let response = try await SocketClient.send(.ping)
        switch response {
        case .pong:
            print("pong")
        default:
            print("unexpected response from daemon: \(response)")
        }
    }
}

/// Verifies and unpacks a signed tarball bundle.
struct Pull: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Verifies and unpacks a signed tarball."
    )

    @Argument(help: "Path to the tarball to pull.")
    var tarballPath: String

    @Option(
        name: .customLong("verify-key"),
        help: "Path to the Ed25519 public key file to verify the manifest's signature against."
    )
    var verifyKeyPath: String

    /// Resolves the tarball and verify-key paths to absolute paths
    /// relative to darwin-run's own working directory, since the daemon's
    /// working directory (set by launchd) has no relation to wherever the
    /// user actually ran this command from. The manifest path is not a
    /// separate flag: by convention it always lives alongside the
    /// tarball, named "<tarball>.manifest.json".
    func run() async throws {
        let absoluteTarballPath = URL(fileURLWithPath: tarballPath).path
        let absoluteManifestPath = absoluteTarballPath + ".manifest.json"
        let absoluteVerifyKeyPath = URL(fileURLWithPath: verifyKeyPath).path

        let config = PullConfig(
            tarballPath: absoluteTarballPath,
            manifestPath: absoluteManifestPath,
            verifyKeyPath: absoluteVerifyKeyPath
        )

        let response = try await SocketClient.send(.pull(config))
        switch response {
        case .pulled(let bundleID, let rootfsPath):
            print("pulled bundle \(bundleID)")
            print("unpacked to \(rootfsPath)")
        case .error(let message):
            print("error: \(message)")
        default:
            print("unexpected response from daemon: \(response)")
        }
    }
}

/// Runs a binary from an already-pulled bundle, sandboxed and
/// resource-limited according to the given flags.
struct Exec: AsyncParsableCommand {
    // Note on flag placement: --cpu-limit, --memory-limit, and
    // --no-isolated must all come BEFORE rootfsPath, not after. The
    // `arguments` field below uses .remaining parsing, meaning
    // everything after binaryPath is treated as literal arguments to
    // hand the job itself - including anything that looks like one of
    // this command's own flags. This is the same convention tools like
    // `env` and `cargo run --` use (wrapper flags first, then the target
    // and its own arguments), and it was found the hard way: an early
    // manual test placed --no-isolated after the positional arguments,
    // where it was silently passed through to the job instead of being
    // parsed by darwin-run at all.
    static let configuration = CommandConfiguration(
        abstract: "Runs a binary from an unpacked bundle. Put --cpu-limit/--memory-limit/--no-isolated BEFORE the rootfs path, not after - anything after the binary path is passed through to the job itself."
    )

    @Argument(help: "Path to the unpacked bundle's rootfs (printed by `darwin-run pull`).")
    var rootfsPath: String

    @Argument(help: "Path to the binary to run, relative to the rootfs (e.g. /app).")
    var binaryPath: String

    @Argument(parsing: .remaining, help: "Arguments to pass to the binary.")
    var arguments: [String] = []

    @Option(name: .customLong("cpu-limit"), help: "CPU time limit in seconds.")
    var cpuLimit: Int?

    @Option(
        name: .customLong("memory-limit"),
        help: "Memory limit in megabytes. Accepted but not currently enforceable on macOS; see README."
    )
    var memoryLimitMB: Int?

    @Flag(
        name: .customLong("no-isolated"),
        help: "Run without Seatbelt sandboxing (POSIX path-jail only). Not recommended."
    )
    var noIsolated: Bool = false

    /// Resolves the rootfs path to an absolute path (same reasoning as
    /// Pull: the daemon's working directory has no relation to where the
    /// user ran this command from), builds an ExecConfig, and prints the
    /// job ID the daemon assigns once it accepts the request.
    func run() async throws {
        let absoluteRootfsPath = URL(fileURLWithPath: rootfsPath).path

        let config = ExecConfig(
            binaryPath: binaryPath,
            arguments: arguments,
            rootfsPath: absoluteRootfsPath,
            cpuLimit: cpuLimit,
            memoryLimitMB: memoryLimitMB,
            isolated: !noIsolated
        )

        let response = try await SocketClient.send(.exec(config))
        switch response {
        case .jobStarted(let jobID):
            print("job started: \(jobID)")
        case .error(let message):
            print("error: \(message)")
        default:
            print("unexpected response from daemon: \(response)")
        }
    }
}

/// Sends a stop signal to a running job by its ID.
struct Stop: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Stops a running job by ID."
    )

    @Argument(help: "The ID of the job to stop.")
    var jobID: String

    /// Sends an IPCMessage.stop. The daemon replies as soon as it has
    /// issued SIGTERM, not once the process has actually exited - use
    /// `darwin-run status` afterward to watch it actually finish.
    func run() async throws {
        let response = try await SocketClient.send(.stop(jobID: jobID))
        switch response {
        case .stopped(let jobID):
            print("stop signal sent to job \(jobID)")
        case .error(let message):
            print("error: \(message)")
        default:
            print("unexpected response from daemon: \(response)")
        }
    }
}

/// Starts streaming a running job's real memory/CPU telemetry to an
/// OTLP collector, running until the job itself finishes.
struct Stats: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Streams real memory/CPU telemetry for a running job to an OTLP collector."
    )

    @Argument(help: "The ID of the job to stream stats for.")
    var jobID: String

    @Option(
        name: .customLong("stream-otel"),
        help: "OTLP/HTTP+JSON collector endpoint, e.g. http://localhost:4318/v1/metrics."
    )
    var endpoint: String

    /// Sends an IPCMessage.stats. The daemon replies as soon as it has
    /// confirmed the job is running and started its background sampling
    /// loop - not once any data has actually been exported. Streaming
    /// only works for genuinely compiled job binaries; a job whose
    /// binary was a shebang script will have its sampling loop give up
    /// after a few failed attempts, logged on the daemon side (see
    /// JobSigner and DEBUGGING_LOG.md #13).
    func run() async throws {
        let response = try await SocketClient.send(.stats(jobID: jobID, endpoint: endpoint))
        switch response {
        case .statsStarted(let jobID):
            print("streaming stats for job \(jobID) to \(endpoint)")
        case .error(let message):
            print("error: \(message)")
        default:
            print("unexpected response from daemon: \(response)")
        }
    }
}

/// Looks up the current status of a job by its ID.
struct Status: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Looks up the status of a job by ID."
    )

    @Argument(help: "The ID of the job to look up.")
    var jobID: String

    /// Sends an IPCMessage.status for the given job ID and prints the
    /// daemon's reply in a human-readable form.
    func run() async throws {
        let response = try await SocketClient.send(.status(jobID: jobID))
        switch response {
        case .jobStatus(let jobID, let state, let exitCode):
            if let exitCode {
                print("job \(jobID): \(state.rawValue), exit code \(exitCode)")
            } else {
                print("job \(jobID): \(state.rawValue)")
            }
        case .error(let message):
            print("error: \(message)")
        default:
            print("unexpected response from daemon: \(response)")
        }
    }
}
