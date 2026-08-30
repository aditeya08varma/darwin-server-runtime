// Signs a tarball for darwin-run pull. This is a real, permanent gap the
// project would otherwise have: every isolation, sandboxing, and
// telemetry component was built and verified in this project, but no
// darwin-run subcommand exists to actually produce a signature - every
// time this project needed one during development, it was generated with
// throwaway code written into main.swift and deleted again afterward.
// This script is that missing piece, made permanent instead of
// disposable.
//
// Runs as a standalone script (`swift scripts/sign-bundle.swift <tarball>`),
// not through the package's own build - it only needs Foundation and
// CryptoKit, both native Apple frameworks, so no SPM target linking is
// required at all. Generates a fresh Ed25519 keypair every run: this is
// a development convenience, not a real key management story - the
// private key is used once to sign and then simply discarded, appropriate
// for locally testing darwin-run pull, not for actually distributing
// bundles to anyone else.
import Foundation
import CryptoKit

guard CommandLine.arguments.count == 2 else {
    print("usage: swift scripts/sign-bundle.swift <tarball-path>")
    exit(1)
}

let tarballPath = CommandLine.arguments[1]
let tarballURL = URL(fileURLWithPath: tarballPath)

let privateKey = Curve25519.Signing.PrivateKey()
let tarballData = try Data(contentsOf: tarballURL)
let digest = SHA256.hash(data: tarballData)
let hashHex = digest.map { String(format: "%02x", $0) }.joined()
let signature = try privateKey.signature(for: Data(digest))

// Matches RuntimeCore.BundleManifest's Codable shape exactly (sha256,
// signature, publicKeyHint) without importing that type directly, since
// a standalone script has no access to the package's own compiled
// modules - see DEBUGGING_LOG.md #3 for why that doesn't work cleanly.
let manifest: [String: Any] = [
    "sha256": hashHex,
    "signature": signature.base64EncodedString(),
    "publicKeyHint": NSNull()
]
let manifestData = try JSONSerialization.data(withJSONObject: manifest)
try manifestData.write(to: URL(fileURLWithPath: tarballPath + ".manifest.json"))

let keyPath = tarballURL.deletingLastPathComponent().appendingPathComponent("verify-key.pub")
try privateKey.publicKey.rawRepresentation.base64EncodedString().write(to: keyPath, atomically: true, encoding: .utf8)

print("signed \(tarballPath)")
print("manifest: \(tarballPath).manifest.json")
print("public key: \(keyPath.path)")
