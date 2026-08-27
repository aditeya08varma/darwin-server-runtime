// ImageStore will hold tarball unpacking (via CSystemBridge/libarchive) and
// Ed25519/SHA-256 signature verification (via CryptoKit), built out in
// Stage 2. This file is a placeholder so the target compiles and the
// dependency graph in Package.swift (ImageStore depends on RuntimeCore and
// CSystemBridge) is already exercised before any real logic exists.
import Foundation
import RuntimeCore

/// A placeholder namespace for the ImageStore module.
public enum ImageStore {
    /// Returns a fixed status string.
    /// Used as a smoke test that ImageStore compiles and can see RuntimeCore,
    /// before real unpacking and verification logic is added in Stage 2.
    public static func status() -> String {
        return "ImageStore ready (stage 0 stub), RuntimeCore version \(RuntimeCore.version())"
    }
}
