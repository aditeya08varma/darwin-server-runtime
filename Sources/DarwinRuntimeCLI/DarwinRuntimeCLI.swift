// Entry point for darwin-run, the user-facing command line client. Each
// subcommand below builds one IPCMessage, sends it through SocketClient,
// and prints a human-readable version of whatever IPCResponse comes back.
// exec is still unimplemented: the daemon itself already replies honestly
// that it's unimplemented until Stage 3.
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
        subcommands: [Ping.self, Pull.self, Status.self]
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

/// Looks up the current status of a job by its ID.
struct Status: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Looks up the status of a job by ID."
    )

    @Argument(help: "The ID of the job to look up.")
    var jobID: String

    /// Sends an IPCMessage.status for the given job ID and prints the
    /// daemon's reply in a human-readable form. In Stage 1 no job can
    /// actually exist yet (exec is unimplemented until Stage 3), so this
    /// will always honestly report "no such job" for now.
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
