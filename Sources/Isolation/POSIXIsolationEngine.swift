// The fallback ProcessIsolationEngine backend: no Seatbelt, no SBPL
// profile, just plain POSIX process spawning with a path-jail check
// before launch. This is deliberately weaker than the Seatbelt backend
// (it cannot stop the process from opening arbitrary files or sockets
// once it's running, the way a real sandbox profile can), but it never
// depends on sandbox-exec at all, so it keeps working even if some future
// macOS release changes or removes that undocumented mechanism.
import Foundation
import RuntimeCore

public final class POSIXIsolationEngine: ProcessIsolationEngine {
    public init() {}

    /// Resolves config.binaryPath against rootfs, confirms it actually
    /// stays inside rootfs, and returns a Process configured to run it
    /// with rootfs as its working directory - not yet launched, so the
    /// caller can still attach stdout/stderr pipes first. CPU limits, if
    /// requested, are applied via ResourceLimits.apply (see that file for
    /// why memory limits cannot be enforced the same way on macOS).
    public func spawn(_ config: ExecConfig, rootfs: URL) throws -> Process {
        let binaryURL = try BinaryPathResolver.resolve(config.binaryPath, within: rootfs)

        let process = Process()
        process.executableURL = binaryURL
        process.arguments = config.arguments
        process.currentDirectoryURL = rootfs
        ResourceLimits.apply(config, to: process)
        return process
    }
}
