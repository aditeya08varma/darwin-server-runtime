// Security-focused tests for ImageStore (path traversal, signature
// verification) and Isolation (sandbox escape attempts). Stage 3 adds the
// Isolation-side tests; ImageArchive's real unpacking tests are here now.
import XCTest
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
}
