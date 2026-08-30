// Security-focused tests for ImageStore (path traversal, signature
// verification) and Isolation (sandbox escape attempts). Stage 3 adds the
// Isolation-side tests; ImageArchive's real unpacking tests are here now.
import XCTest
import CryptoKit
@testable import ImageStore
@testable import Isolation

final class SandboxSecurityTests: XCTestCase {
    /// A fresh temporary directory for one test's tarball and rootfs, so
    /// tests never share files or interfere with each other.
    private var workDirectory: URL!

    override func setUpWithError() throws {
        workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SandboxSecurityTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDirectory)
    }

    /// Checks that both ImageStore and Isolation report their placeholder
    /// status strings. Exists only to prove this test target builds and can
    /// see both modules before real security tests are written in Stages 2 and 3.
    func testPlaceholderModulesAreReachable() {
        XCTAssertFalse(ImageStore.status().isEmpty)
        XCTAssertFalse(Isolation.status().isEmpty)
    }

    /// The core positive case: a normal, well-behaved tarball unpacks
    /// correctly, including a nested directory, and the extracted files'
    /// contents match exactly what was written into the fixture.
    func testUnpackExtractsFilesAndNestedDirectoriesCorrectly() throws {
        let tarball = workDirectory.appendingPathComponent("valid.tar.gz")
        let rootfs = workDirectory.appendingPathComponent("rootfs")

        try TarballFixture.write(
            entries: [
                TarballFixture.Entry(path: "hello.txt", content: "hello world"),
                TarballFixture.Entry(path: "nested/dir/file.txt", content: "nested content")
            ],
            to: tarball
        )

        try ImageArchive.unpack(tarball: tarball, into: rootfs)

        let helloContent = try String(contentsOf: rootfs.appendingPathComponent("hello.txt"), encoding: .utf8)
        XCTAssertEqual(helloContent, "hello world")

        let nestedContent = try String(
            contentsOf: rootfs.appendingPathComponent("nested/dir/file.txt"),
            encoding: .utf8
        )
        XCTAssertEqual(nestedContent, "nested content")
    }

    /// The security-critical negative case: a tarball containing an entry
    /// whose path escapes the destination directory using "../" segments
    /// must be rejected, and - just as importantly - must not have written
    /// anything to the escape target before the rejection happened.
    func testUnpackRejectsPathTraversalEntry() throws {
        let tarball = workDirectory.appendingPathComponent("malicious.tar.gz")
        let rootfs = workDirectory.appendingPathComponent("rootfs")
        let escapeTarget = workDirectory.appendingPathComponent("escaped-file.txt")

        try TarballFixture.write(
            entries: [
                TarballFixture.Entry(path: "../escaped-file.txt", content: "should never be written")
            ],
            to: tarball
        )

        XCTAssertThrowsError(try ImageArchive.unpack(tarball: tarball, into: rootfs)) { error in
            guard case ImageArchiveError.unsafeEntryPath = error else {
                XCTFail("expected unsafeEntryPath, got \(error)")
                return
            }
        }

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: escapeTarget.path),
            "path traversal entry must never be written to disk, even outside rootfs"
        )
    }

    /// A second variant of the same attack: an absolute path instead of a
    /// relative "../" one. Also must be rejected before writing anything.
    func testUnpackRejectsAbsolutePathEntry() throws {
        let tarball = workDirectory.appendingPathComponent("absolute.tar.gz")
        let rootfs = workDirectory.appendingPathComponent("rootfs")

        try TarballFixture.write(
            entries: [
                TarballFixture.Entry(path: "/tmp/should-never-exist-\(UUID().uuidString).txt", content: "bad")
            ],
            to: tarball
        )

        XCTAssertThrowsError(try ImageArchive.unpack(tarball: tarball, into: rootfs)) { error in
            guard case ImageArchiveError.unsafeEntryPath = error else {
                XCTFail("expected unsafeEntryPath, got \(error)")
                return
            }
        }
    }

    /// The core positive case for TrustVerifier: a tarball with a real,
    /// validly signed manifest verifies successfully with no error.
    func testVerifyAcceptsValidSignedManifest() throws {
        let tarball = workDirectory.appendingPathComponent("bundle.tar.gz")
        let manifestURL = workDirectory.appendingPathComponent("bundle.manifest.json")

        try TarballFixture.write(entries: [TarballFixture.Entry(path: "app", content: "version 1")], to: tarball)
        let publicKey = try SigningFixture.writeValidManifest(forTarballAt: tarball, to: manifestURL)

        XCTAssertNoThrow(try TrustVerifier.verify(tarball: tarball, manifest: manifestURL, publicKey: publicKey))
    }

    /// If the tarball's bytes change after signing (a corrupted download,
    /// or someone swapping in a different file at the same path) without
    /// the manifest being updated to match, the hash check must catch it.
    func testVerifyRejectsTarballThatDoesNotMatchManifestHash() throws {
        let tarball = workDirectory.appendingPathComponent("bundle.tar.gz")
        let manifestURL = workDirectory.appendingPathComponent("bundle.manifest.json")

        try TarballFixture.write(entries: [TarballFixture.Entry(path: "app", content: "version 1")], to: tarball)
        let publicKey = try SigningFixture.writeValidManifest(forTarballAt: tarball, to: manifestURL)

        // Overwrite the tarball after the manifest was already signed for
        // its original contents.
        try "completely different bytes".data(using: .utf8)!.write(to: tarball)

        XCTAssertThrowsError(try TrustVerifier.verify(tarball: tarball, manifest: manifestURL, publicKey: publicKey)) { error in
            guard case TrustVerifierError.hashMismatch = error else {
                XCTFail("expected hashMismatch, got \(error)")
                return
            }
        }
    }

    /// If the manifest was signed by a different private key than the one
    /// the caller expects (publicKey here), verification must fail even
    /// though the hash matches perfectly, since the hash alone says
    /// nothing about who produced the bundle.
    func testVerifyRejectsSignatureFromWrongKey() throws {
        let tarball = workDirectory.appendingPathComponent("bundle.tar.gz")
        let manifestURL = workDirectory.appendingPathComponent("bundle.manifest.json")

        try TarballFixture.write(entries: [TarballFixture.Entry(path: "app", content: "version 1")], to: tarball)
        _ = try SigningFixture.writeValidManifest(forTarballAt: tarball, to: manifestURL)

        let unrelatedKeyPair = Curve25519.Signing.PrivateKey()

        XCTAssertThrowsError(
            try TrustVerifier.verify(tarball: tarball, manifest: manifestURL, publicKey: unrelatedKeyPair.publicKey)
        ) { error in
            guard case TrustVerifierError.invalidSignature = error else {
                XCTFail("expected invalidSignature, got \(error)")
                return
            }
        }
    }

    /// The attack the two checks together are meant to catch: an attacker
    /// swaps in a different tarball and rewrites the manifest's sha256
    /// field to match it (so the hash check alone would pass), but cannot
    /// produce a new valid signature without the private key, so the old
    /// signature is left in place. The signature check must catch this
    /// even though the hash check on its own would not have.
    func testVerifyRejectsHashRewrittenToMatchSwappedTarball() throws {
        let tarball = workDirectory.appendingPathComponent("bundle.tar.gz")
        let manifestURL = workDirectory.appendingPathComponent("bundle.manifest.json")

        try TarballFixture.write(entries: [TarballFixture.Entry(path: "app", content: "version 1")], to: tarball)
        let publicKey = try SigningFixture.writeValidManifest(forTarballAt: tarball, to: manifestURL)
        let originalManifest = try JSONDecoder().decode(BundleManifest.self, from: Data(contentsOf: manifestURL))

        // Swap in a different tarball entirely.
        try TarballFixture.write(entries: [TarballFixture.Entry(path: "app", content: "malicious version")], to: tarball)
        let newHash = SHA256.hash(data: try Data(contentsOf: tarball)).map { String(format: "%02x", $0) }.joined()

        // Rewrite the manifest's hash to match the new tarball, but keep
        // the old signature, since forging a new one requires the private
        // key, which an attacker does not have.
        let forgedManifest = BundleManifest(
            sha256: newHash,
            signature: originalManifest.signature,
            publicKeyHint: originalManifest.publicKeyHint
        )
        try JSONEncoder().encode(forgedManifest).write(to: manifestURL)

        XCTAssertThrowsError(try TrustVerifier.verify(tarball: tarball, manifest: manifestURL, publicKey: publicKey)) { error in
            guard case TrustVerifierError.invalidSignature = error else {
                XCTFail("expected invalidSignature (hash check alone would have passed here), got \(error)")
                return
            }
        }
    }

    /// TrustVerifier.loadPublicKey must correctly round-trip a key written
    /// in the same base64 format darwin-run pull's --verify-key file uses.
    func testLoadPublicKeyRoundTripsCorrectly() throws {
        let keyURL = workDirectory.appendingPathComponent("key.pub")
        let originalKey = Curve25519.Signing.PrivateKey().publicKey

        try SigningFixture.writePublicKey(originalKey, to: keyURL)
        let loadedKey = try TrustVerifier.loadPublicKey(from: keyURL)

        XCTAssertEqual(loadedKey.rawRepresentation, originalKey.rawRepresentation)
    }
}
