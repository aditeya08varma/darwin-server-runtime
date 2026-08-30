// Shared by every ProcessIsolationEngine backend: resolving an
// ExecConfig's binaryPath against a rootfs and confirming the result
// genuinely stays inside it. Originally lived only inside
// POSIXIsolationEngine, but SeatbeltIsolationEngine needs the exact same
// resolution (it still has to know which real file to tell sandbox-exec
// to run), so it was pulled out here rather than duplicated a second time
// - the same reasoning that moved the ".." check itself into
// RuntimeCore.PathSafety.
import Foundation
import RuntimeCore

enum BinaryPathResolver {
    /// Resolves `binaryPath` as if `rootfs` were the filesystem root (so
    /// a config value like "/bin/echo" means "bin/echo inside rootfs",
    /// not the real /bin/echo on this Mac), then confirms the resolved
    /// path genuinely stays inside rootfs using RealPath.canonicalize -
    /// the same defense-in-depth reasoning as ImageArchive's
    /// path-traversal guard, checked again here at execution time since a
    /// rootfs could, in principle, be modified between when it was
    /// unpacked and when it's actually run. Uses RealPath rather than
    /// Foundation's own resolvingSymlinksInPath specifically because the
    /// resulting path also gets handed to SeatbeltIsolationEngine's
    /// sandbox-exec profile, which is checked against the kernel's true
    /// canonical path - see RealPath.swift for why that distinction
    /// matters here and not just being a style preference.
    static func resolve(_ binaryPath: String, within rootfs: URL) throws -> URL {
        let trimmedPath = binaryPath.hasPrefix("/") ? String(binaryPath.dropFirst()) : binaryPath
        do {
            try PathSafety.validateRelativePath(trimmedPath)
        } catch {
            // Translated to IsolationError so callers only ever need to
            // catch one error type from this module, the same pattern
            // ImageArchive uses for the same underlying check.
            throw IsolationError.binaryEscapesRootfs(binaryPath)
        }

        let rootfsResolved = RealPath.canonicalize(rootfs)
        let candidate = RealPath.canonicalize(rootfsResolved.appendingPathComponent(trimmedPath))

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
