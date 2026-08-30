// The primary ProcessIsolationEngine backend: real Seatbelt sandboxing
// via /usr/bin/sandbox-exec with a dynamically generated SBPL profile.
// Unlike POSIXIsolationEngine's one-time path check, a Seatbelt profile
// is enforced continuously by the kernel for the process's entire
// lifetime - every file open, not just the initial binary path, is
// checked against the profile.
//
// The profile below was worked out by hand, iterating directly against
// real `sandbox-exec` invocations and reading the exact denial reasons
// out of the unified log (see DEBUGGING_LOG.md), not written from
// documentation alone - Apple does not publish official SBPL reference
// docs. A few of its rules only make sense once you know the specific
// failure they fix:
//   - `(allow file-read-metadata (literal "/tmp"))`: /tmp is itself a
//     symlink to /private/tmp on macOS. Resolving a path that starts
//     with /tmp requires reading metadata on the symlink itself, which
//     is a separate permission from reading whatever it points to.
//   - `(allow file-read* (literal "/"))`: the shell and dynamic linker
//     both probe the root directory during startup even when never
//     asked to read anything under it directly.
//   - `(allow sysctl-read)`: needed for basic process startup checks
//     (kern.bootargs, security.mac.lockdown_mode_state, and others);
//     without it the process aborts before it even runs.
import Foundation
import RuntimeCore
import os.log

private let logger = Logger(subsystem: "com.aditeya.darwin-runtime", category: "seatbelt")

public final class SeatbeltIsolationEngine: ProcessIsolationEngine {
    public init() {}

    /// Resolves and validates the binary path exactly as
    /// POSIXIsolationEngine does, then wraps it in a sandbox-exec
    /// invocation carrying a profile generated specifically for this
    /// rootfs. Resource limits are applied the same way as the POSIX
    /// backend, on top of the sandboxed command.
    public func spawn(_ config: ExecConfig, rootfs: URL) throws -> Process {
        let binaryURL = try BinaryPathResolver.resolve(config.binaryPath, within: rootfs)
        let rootfsResolved = RealPath.canonicalize(rootfs)

        let profilePath = try writeProfile(forRootfs: rootfsResolved)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        process.arguments = ["-f", profilePath.path, binaryURL.path] + config.arguments
        process.currentDirectoryURL = rootfsResolved
        ResourceLimits.apply(config, to: process)
        return process
    }

    /// Builds the SBPL profile text for one job, confined to `rootfs`,
    /// and writes it to a uniquely named file under the system temporary
    /// directory. sandbox-exec reads the profile from disk via -f, so it
    /// has to exist as a real file at the time the process actually
    /// launches - not yet, at spawn() time, since the caller may still
    /// launch this Process some time later. Cleaning up this file once
    /// the process has started is a known gap, not solved here: Process
    /// only supports a single terminationHandler, and attaching one here
    /// would risk silently overwriting whatever ProcessSupervisor sets in
    /// a later component.
    private func writeProfile(forRootfs rootfs: URL) throws -> URL {
        let profile = """
        (version 1)
        (deny default)
        (allow process-exec)
        (allow process-fork)
        (allow sysctl-read)
        (allow file-read* (subpath "/usr/lib"))
        (allow file-read* (subpath "/System/Library"))
        (allow file-read* (subpath "/bin"))
        (allow file-read* (literal "/dev/null"))
        (allow file-read* (literal "/"))
        (allow file-read-metadata (literal "/tmp"))
        (allow file-read* file-write* (subpath "\(rootfs.path)"))
        """

        let profileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("darwin-runtime-profile-\(UUID().uuidString).sb")

        do {
            try profile.write(to: profileURL, atomically: true, encoding: .utf8)
        } catch {
            throw IsolationError.profileWriteFailed("\(error)")
        }

        logger.info("wrote sandbox profile for rootfs \(rootfs.path, privacy: .public) to \(profileURL.path, privacy: .public)")
        return profileURL
    }
}
