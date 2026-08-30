// Verifies that a tarball matches a signed manifest before ImageArchive
// ever unpacks it. This addresses a different question than the path
// traversal guard: that guard stops a tarball's contents from writing
// somewhere they shouldn't, regardless of who sent the tarball. This file
// asks whether the tarball can be trusted at all: was it produced by
// whoever holds the expected private key, and has it been modified since
// they signed it? Both checks are independent and neither substitutes
// for the other.
import Foundation
import CryptoKit

/// The JSON sidecar file that travels alongside a tarball, named
/// `<bundle>.manifest.json` by convention. sha256 is the tarball's own
/// hash, hex-encoded; signature is an Ed25519 signature over that hash's
/// raw bytes, base64-encoded; publicKeyHint is an optional, purely
/// informational label (not used for verification itself) that helps a
/// human figure out which key was supposed to have signed this.
public struct BundleManifest: Codable, Equatable {
    public let sha256: String
    public let signature: String
    public let publicKeyHint: String?

    public init(sha256: String, signature: String, publicKeyHint: String? = nil) {
        self.sha256 = sha256
        self.signature = signature
        self.publicKeyHint = publicKeyHint
    }
}

public enum TrustVerifierError: Error, CustomStringConvertible {
    case manifestDecodeFailed(String)
    case hashMismatch(expected: String, actual: String)
    case malformedSignature(String)
    case malformedPublicKey(String)
    case invalidSignature

    public var description: String {
        switch self {
        case .manifestDecodeFailed(let message):
            return "could not decode manifest: \(message)"
        case .hashMismatch(let expected, let actual):
            return "tarball hash does not match manifest: expected \(expected), got \(actual)"
        case .malformedSignature(let message):
            return "manifest signature is malformed: \(message)"
        case .malformedPublicKey(let message):
            return "public key is malformed: \(message)"
        case .invalidSignature:
            return "signature does not verify against the given public key"
        }
    }
}

/// Verifies a tarball against its signed manifest using Ed25519.
public enum TrustVerifier {
    /// Loads a Curve25519 Ed25519 public key from a file containing its
    /// base64-encoded raw bytes (32 bytes before encoding). This is the
    /// format expected at the path passed to `darwin-run pull --verify-key`.
    public static func loadPublicKey(from url: URL) throws -> Curve25519.Signing.PublicKey {
        let rawText = try String(contentsOf: url, encoding: .utf8)
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let keyData = Data(base64Encoded: trimmed) else {
            throw TrustVerifierError.malformedPublicKey("not valid base64: \(url.path)")
        }
        do {
            return try Curve25519.Signing.PublicKey(rawRepresentation: keyData)
        } catch {
            throw TrustVerifierError.malformedPublicKey("not a valid Ed25519 public key: \(error)")
        }
    }

    /// Verifies that `tarball` matches `manifest` and is validly signed by
    /// `publicKey`. Two checks happen, in order, and either one failing
    /// stops the whole verification: first, the tarball's own SHA-256
    /// hash must match the hash recorded in the manifest (this catches
    /// any tampering with the tarball's bytes after the manifest was
    /// written). Second, the manifest's signature must be a valid Ed25519
    /// signature, made by the holder of the private key matching
    /// `publicKey`, over that same hash (this catches a manifest whose
    /// hash field was simply rewritten to match a swapped-in tarball,
    /// since a forged manifest cannot also produce a valid signature
    /// without the matching private key).
    public static func verify(
        tarball: URL,
        manifest manifestURL: URL,
        publicKey: Curve25519.Signing.PublicKey
    ) throws {
        let manifestData = try Data(contentsOf: manifestURL)
        let manifest: BundleManifest
        do {
            manifest = try JSONDecoder().decode(BundleManifest.self, from: manifestData)
        } catch {
            throw TrustVerifierError.manifestDecodeFailed("\(error)")
        }

        let tarballData = try Data(contentsOf: tarball)
        let actualDigest = SHA256.hash(data: tarballData)
        let actualHashHex = actualDigest.map { String(format: "%02x", $0) }.joined()

        guard actualHashHex == manifest.sha256 else {
            throw TrustVerifierError.hashMismatch(expected: manifest.sha256, actual: actualHashHex)
        }

        guard let signatureData = Data(base64Encoded: manifest.signature) else {
            throw TrustVerifierError.malformedSignature("not valid base64: \(manifest.signature)")
        }

        let hashBytes = Data(actualDigest)
        guard publicKey.isValidSignature(signatureData, for: hashBytes) else {
            throw TrustVerifierError.invalidSignature
        }
    }
}
