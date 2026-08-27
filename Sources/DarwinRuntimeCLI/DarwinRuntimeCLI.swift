// Entry point for darwin-run, the user-facing command line client. Real
// subcommands (pull, exec, stats) are wired up to talk to the daemon over
// its Unix domain socket starting in Stage 1; for now there is only a
// placeholder ping subcommand that proves the executable builds and that
// swift-argument-parser is wired in correctly.
import ArgumentParser

/// The top-level darwin-run command.
/// This is the parent command that argument-parser dispatches to one of the
/// subcommands listed below; it carries no logic of its own.
@main
struct DarwinRun: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "darwin-run",
        abstract: "Client for the darwin-server-runtime daemon.",
        subcommands: [Ping.self]
    )
}

/// A placeholder subcommand that does not talk to the daemon yet.
/// It exists so we have a working, testable subcommand from Stage 0, before
/// Stage 1 replaces it with a real ping that round-trips over the socket.
struct Ping: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Stage 0 placeholder: prints pong without contacting the daemon."
    )

    /// Prints a fixed response.
    /// Runs when the user types `darwin-run ping`; in Stage 1 this is
    /// replaced with logic that actually sends a message over the socket.
    func run() throws {
        print("pong (stage 0 placeholder, not yet talking to the daemon)")
    }
}
