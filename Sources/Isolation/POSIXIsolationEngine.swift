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
        let binaryURL = try resolveBinaryPath(config.binaryPath, within: rootfs)

        let process = Process()
        process.executableURL = binaryURL
        process.arguments = config.arguments
        process.currentDirectoryURL = rootfs
        ResourceLimits.apply(config, to: process)
        return process
    }

    /// Resolves `binaryPath` as if `rootfs` were the filesystem root (so
    /// a config value like "/bin/echo" means "bin/echo inside rootfs",
    /// not "the real /bin/echo on this Mac"), then confirms the resolved
    /// path genuinely stays inside rootfs using resolvingSymlinksInPath -
    /// this is the same defense-in-depth reasoning as ImageArchive's
    /// path-traversal guard, checked again here at execution time since a
    /// rootfs could, in principle, be modified between when it was
    /// unpacked and when it's actually run.
    private func resolveBinaryPath(_ binaryPath: String, within rootfs: URL) throws -> URL {
        let trimmedPath = binaryPath.hasPrefix("/") ? String(binaryPath.dropFirst()) : binaryPath
        do {
            try PathSafety.validateRelativePath(trimmedPath)
        } catch {
            // Translated to IsolationError so callers only ever need to
            // catch one error type from this module, the same pattern
            // ImageArchive uses for the same underlying check.
            throw IsolationError.binaryEscapesRootfs(binaryPath)
        }

        let rootfsResolved = rootfs.resolvingSymlinksInPath().standardizedFileURL
        let candidate = rootfsResolved
            .appendingPathComponent(trimmedPath)
            .resolvingSymlinksInPath()
            .standardizedFileURL

        let rootfsPrefix = rootfsResolved.path.hasSuffix("/") ? rootfsResolved.path : rootfsResolved.path + "/"
        guard candidate.path.hasPrefix(rootfsPrefix) else {
            throw IsolationError.binaryEscapesRootfs(binaryPath)
        }
        guard FileManager.default.isExecutableFile(atPath: candidate.path) else {
            throw IsolationError.binaryNotFound(binaryPath)
        }
        return candidate
    }
}
