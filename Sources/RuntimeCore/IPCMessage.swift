// The shared wire protocol between darwin-run (CLI) and darwin-runtimed
// (daemon). Both sides import RuntimeCore and use these exact types, so
// there is only one place that defines "what a request/response looks
// like" instead of each side guessing at a shared format.
import Foundation

/// A configuration bundle describing one workload to run.
/// This is carried inside an .exec message. The daemon does not act on it
/// yet in Stage 1: Stage 3 is where it actually gets turned into a real,
/// sandboxed, resource-limited child process.
public struct ExecConfig: Codable, Sendable, Equatable {
    /// Path to the executable, inside the unpacked rootfs, that should be run.
    public var binaryPath: String

    /// Command-line arguments passed to that executable.
    public var arguments: [String]

    /// The filesystem root the process should be confined to once
    /// sandboxing is wired up in Stage 3.
    public var rootfsPath: String

    /// Optional CPU limit requested by the caller. Mapped to setrlimit in Stage 3.
    public var cpuLimit: Int?

    /// Optional memory ceiling in megabytes requested by the caller.
    /// Mapped to the best-effort RLIMIT_AS constraint in Stage 3.
    public var memoryLimitMB: Int?

    /// Whether the process should run inside the Seatbelt sandbox at all.
    public var isolated: Bool

    /// Builds a new ExecConfig from values supplied by the caller (the CLI).
    /// Arguments default to empty and isolated defaults to true, so the
    /// common case ("just run this binary, sandboxed") stays short to write.
    public init(
        binaryPath: String,
        arguments: [String] = [],
        rootfsPath: String,
        cpuLimit: Int? = nil,
        memoryLimitMB: Int? = nil,
        isolated: Bool = true
    ) {
        self.binaryPath = binaryPath
        self.arguments = arguments
        self.rootfsPath = rootfsPath
        self.cpuLimit = cpuLimit
        self.memoryLimitMB = memoryLimitMB
        self.isolated = isolated
    }
}

/// A request to verify and unpack a local tarball, sent by `darwin-run
/// pull`. All three paths are filesystem paths on the machine both the
/// CLI and the daemon share (this is a local dev tool, not a network
/// upload), and must already be absolute by the time this is sent: the
/// CLI resolves them against its own working directory before sending,
/// since the daemon's working directory (set by launchd) has no relation
/// to wherever the user actually ran darwin-run from.
public struct PullConfig: Codable, Sendable, Equatable {
    /// Absolute path to the tarball to verify and unpack.
    public var tarballPath: String

    /// Absolute path to the tarball's signed manifest JSON file.
    public var manifestPath: String

    /// Absolute path to the base64-encoded Ed25519 public key file to
    /// verify the manifest's signature against.
    public var verifyKeyPath: String

    public init(tarballPath: String, manifestPath: String, verifyKeyPath: String) {
        self.tarballPath = tarballPath
        self.manifestPath = manifestPath
        self.verifyKeyPath = verifyKeyPath
    }
}

/// Every kind of request the CLI can send to the daemon over the socket.
/// The CLI encodes one of these cases to JSON and sends it; the daemon
/// decodes the same enum and switches on which case arrived to decide what
/// to do. Exactly one case is active per message, which is why this is an
/// enum with associated values rather than one struct with optional fields.
public enum IPCMessage: Codable, Sendable, Equatable {
    /// A liveness check with no side effects. The daemon should reply .pong.
    case ping

    /// A request to verify and unpack a local tarball. See PullConfig.
    case pull(PullConfig)

    /// A request to start running the workload described by the given config.
    case exec(ExecConfig)

    /// A request to stop the job with the given ID.
    case stop(jobID: String)

    /// A request for the current status of the job with the given ID.
    case status(jobID: String)
}

/// Every kind of reply the daemon can send back, always exactly one per request.
public enum IPCResponse: Codable, Sendable, Equatable {
    /// Sent back for .ping, confirming the daemon is alive and listening.
    case pong

    /// Sent back for .pull once the tarball has been verified against its
    /// manifest and successfully unpacked. bundleID identifies the bundle
    /// for future use (Stage 3's .exec will reference bundles by this ID);
    /// rootfsPath is where its contents actually landed on disk.
    case pulled(bundleID: String, rootfsPath: String)

    /// Sent back for .exec once the daemon has accepted the job and
    /// assigned it an ID the caller can use in later .stop/.status requests.
    case jobStarted(jobID: String)

    /// Sent back for .stop, confirming the stop signal (SIGTERM, later
    /// SIGKILL if needed) has been issued to the job. This does not mean
    /// the process has actually exited yet, since that can take a few
    /// seconds during the grace period ProcessSupervisor enforces in
    /// Stage 3 - the daemon replies immediately rather than blocking the
    /// connection until the process is fully dead. Poll .status afterward
    /// to see it actually transition to .killed.
    case stopped(jobID: String)

    /// Sent back for .status: the job's current lifecycle state, and its
    /// exit code once it has actually exited (nil while still running).
    case jobStatus(jobID: String, state: JobState, exitCode: Int32?)

    /// Sent back whenever a request could not be fulfilled, carrying a
    /// human-readable reason the CLI can print directly to the user.
    case error(message: String)
}

/// The lifecycle states a job can be in, reported inside .jobStatus replies.
/// Real transitions between these states are driven by ProcessSupervisor,
/// which is built in Stage 3; for now this just defines the shape.
public enum JobState: String, Codable, Sendable, Equatable {
    case running
    case exited
    case killed
}
