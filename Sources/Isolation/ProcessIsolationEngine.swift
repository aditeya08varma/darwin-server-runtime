// The abstraction that lets the rest of the daemon spawn an isolated
// process without knowing or caring which actual isolation mechanism was
// used. This exists specifically because Seatbelt (sandbox-exec) is a
// private, undocumented Apple mechanism that could change or disappear in
// a future macOS release; POSIXIsolationEngine is a weaker but always-
// available fallback that does not depend on it at all.
import Foundation
import RuntimeCore

public enum IsolationError: Error, CustomStringConvertible {
    case binaryEscapesRootfs(String)
    case binaryNotFound(String)

    public var description: String {
        switch self {
        case .binaryEscapesRootfs(let path):
            return "binary path escapes the rootfs: \(path)"
        case .binaryNotFound(let path):
            return "binary not found or not executable: \(path)"
        }
    }
}

/// A backend capable of preparing an isolated process for one job. Both
/// the Seatbelt and POSIX backends produce a standard Foundation
/// `Process`, fully configured but not yet launched - the rest of the
/// daemon (ProcessSupervisor, in a later component) only ever deals with
/// a normal `Process`, never needing to know which backend prepared it.
///
/// Deliberately not launched here: Process requires its stdout/stderr
/// pipes to be attached before `run()` is called, and attaching those
/// pipes is ProcessSupervisor's job, not the isolation engine's. If
/// `spawn` launched the process itself, no caller could ever attach a
/// pipe in time to capture its output from the very first byte.
public protocol ProcessIsolationEngine {
    /// Validates and configures `config`'s binary to run confined to
    /// `rootfs`, returning a Process ready for its caller to attach
    /// pipes to and launch. Throws if the process could not even be
    /// prepared (missing binary, an escaping path, a failed profile
    /// compilation) - never because of anything that happens after the
    /// process actually starts running, since it has not started yet.
    func spawn(_ config: ExecConfig, rootfs: URL) throws -> Process
}
