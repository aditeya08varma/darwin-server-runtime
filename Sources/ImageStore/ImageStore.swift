// ImageStore holds tarball unpacking (via the CArchive systemLibrary
// target, wrapping libarchive) and Ed25519/SHA-256 signature verification
// (via CryptoKit). ImageArchive.swift has the real unpacking logic; this
// file just proves the CArchive link actually works by calling one real
// libarchive function.
import Foundation
import RuntimeCore
import CArchive

/// A placeholder namespace for the ImageStore module.
public enum ImageStore {
    /// Returns a fixed status string.
    /// Used as a smoke test that ImageStore compiles and can see RuntimeCore,
    /// before real unpacking and verification logic is added in Stage 2.
    public static func status() -> String {
        return "ImageStore ready (stage 0 stub), RuntimeCore version \(RuntimeCore.version())"
    }

    /// Calls libarchive's own archive_version_string() function directly
    /// through CArchive and converts the result to a Swift String. This is
    /// a link and call smoke test: if CArchive's module map or the linker
    /// flags were wrong, this would fail to build or crash at runtime
    /// rather than returning a real version string.
    public static func libarchiveVersion() -> String {
        return String(cString: archive_version_string())
    }
}
