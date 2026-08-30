// A single, shared implementation of the "does this relative path try to
// escape its intended directory" check. This exact check is needed in two
// independent places: ImageArchive, when deciding whether a tarball entry
// is safe to extract, and Isolation, when resolving an ExecConfig's
// binaryPath against a rootfs before spawning it. Keeping one shared
// implementation, rather than two copies that could quietly drift apart
// over time, matters more here than it would for an ordinary helper,
// since this specific check is the one thing standing between a
// malicious path and a real filesystem escape.
import Foundation

public enum PathSafetyError: Error, CustomStringConvertible {
    case unsafePath(String)

    public var description: String {
        switch self {
        case .unsafePath(let path):
            return "unsafe path: \(path)"
        }
    }
}

public enum PathSafety {
    /// Rejects a relative path if it is empty, absolute (starts with
    /// "/"), or contains a ".." path component. Checking by path
    /// component (splitting on "/") rather than checking whether the
    /// string contains ".." anywhere is what makes this correct: it
    /// rejects a real escape attempt like "../../etc/passwd" without also
    /// rejecting a legitimately named file like "foo..bar.txt", which
    /// merely contains the two characters ".." without them forming an
    /// actual path component.
    public static func validateRelativePath(_ path: String) throws {
        if path.isEmpty || path.hasPrefix("/") {
            throw PathSafetyError.unsafePath(path)
        }
        if path.split(separator: "/").contains("..") {
            throw PathSafetyError.unsafePath(path)
        }
    }
}
