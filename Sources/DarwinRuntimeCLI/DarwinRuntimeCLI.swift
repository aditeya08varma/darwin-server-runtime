// Entry point for darwin-run, the user-facing command line client. Each
// subcommand below builds one IPCMessage, sends it through SocketClient,
// and prints a human-readable version of whatever IPCResponse comes back.
// exec and pull are not implemented yet: the daemon itself already replies
// honestly that exec is unimplemented until Stage 3, and pull has no
// client-side command at all yet, added alongside real unpacking in Stage 2.
import ArgumentParser
import RuntimeCore

/// The top-level darwin-run command. Carries no logic of its own; it only
/// declares which subcommands exist and dispatches to whichever one the
/// user invoked. It conforms to AsyncParsableCommand, not the plain
/// ParsableCommand, because both of its subcommands need to await network
/// I/O, and swift-argument-parser requires every command from the root
/// down to be async if any of them are.
@main
struct DarwinRun: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "darwin-run",
        abstract: "Client for the darwin-server-runtime daemon.",
        subcommands: [Ping.self, Status.self]
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
