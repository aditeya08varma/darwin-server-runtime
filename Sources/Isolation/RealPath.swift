// Computes the true, kernel-level canonical path for a filesystem
// location. This exists because Foundation's own
// URL.resolvingSymlinksInPath() deliberately does NOT resolve a specific
// set of legacy compatibility symlinks on macOS - /tmp, /var, and /etc
// are left exactly as written, pointing at /private/tmp, /private/var,
// and /private/etc respectively, rather than being rewritten. That's a
// reasonable choice for most uses, but it's actively wrong for anything
// handed to an external process that does its own independent
// canonicalization at the kernel level - which is exactly what
// sandbox-exec does: an SBPL profile's subpath rules are checked against
// the real, fully resolved path, regardless of what string was written
// in the profile text. If the profile says /var/folders/... but the
// kernel resolves the running process's actual path to
// /private/var/folders/..., the two strings simply don't match and every
// file operation gets denied.
//
// This was discovered the hard way: SeatbeltIsolationEngine's very first
// real test run failed with "Operation not permitted" even though the
// generated profile looked correct by inspection, and comparing
// Foundation's resolvingSymlinksInPath() against a raw realpath() call
// side by side is what revealed the actual discrepancy. See
// DEBUGGING_LOG.md for the full story.
import Foundation

enum RealPath {
    /// Resolves `url` to its true canonical filesystem path using the raw
    /// POSIX realpath() call, not Foundation's higher-level (and, for
    /// this purpose, subtly wrong) resolvingSymlinksInPath(). Falls back
    /// to returning `url` unchanged if realpath() fails, which happens
    /// when the path doesn't exist yet - callers that need the target to
    /// exist already have their own existence check afterward.
    static func canonicalize(_ url: URL) -> URL {
        var buffer = [Int8](repeating: 0, count: Int(PATH_MAX))
        guard realpath(url.path, &buffer) != nil else {
            return url
        }
        return URL(fileURLWithPath: String(cString: buffer))
    }
}
