// A test-only helper for generating Ed25519 keypairs and signed manifests,
// so TrustVerifier's tests can exercise real cryptographic verification
// rather than mocking it. Every manifest built here is a genuine, validly
// signed manifest for the exact tarball bytes given; tests that need an
// invalid manifest tamper with the result afterward, deliberately, the
// same way a real attacker or a corrupted download would.
import Foundation
import CryptoKit
@testable import ImageStore

enum SigningFixture {
    /// Generates a fresh Ed25519 keypair, computes the real SHA-256 hash
    /// of `tarball`'s current contents, signs that hash, and writes a
    /// correctly formed manifest JSON file to `manifestURL`. Returns the
    /// public key half of the pair, which the test then hands to
    /// TrustVerifier.verify - mirroring how darwin-run pull would receive
    /// a public key via --verify-key, separately from the manifest itself.
    static func writeValidManifest(
        forTarballAt tarball: URL,
        to manifestURL: URL
    ) throws -> Curve25519.Signing.PublicKey {
        let privateKey = Curve25519.Signing.PrivateKey()

        let tarballData = try Data(contentsOf: tarball)
        let digest = SHA256.hash(data: tarballData)
        let hashHex = digest.map { String(format: "%02x", $0) }.joined()

        let signature = try privateKey.signature(for: Data(digest))

        let manifest = BundleManifest(
            sha256: hashHex,
            signature: signature.base64EncodedString(),
            publicKeyHint: "test-key"
        )
        let manifestData = try JSONEncoder().encode(manifest)
        try manifestData.write(to: manifestURL)

        return privateKey.publicKey
    }

    /// Writes a base64-encoded public key to disk in the same format
    /// TrustVerifier.loadPublicKey expects to read back, matching what a
    /// real `--verify-key` file would contain.
    static func writePublicKey(_ publicKey: Curve25519.Signing.PublicKey, to url: URL) throws {
        let encoded = publicKey.rawRepresentation.base64EncodedString()
        try encoded.write(to: url, atomically: true, encoding: .utf8)
    }
}
