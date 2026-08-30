// Security-focused tests for ImageStore (path traversal, signature
// verification) and Isolation (sandbox escape attempts). Stage 3 adds the
// Isolation-side tests; ImageArchive's real unpacking tests are here now.
import XCTest
import CryptoKit
import Darwin
import RuntimeCore
@testable import ImageStore
@testable import Isolation
@testable import DarwinDaemon

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

    /// Regression test for a real bug found during Stage 3's end-to-end
    /// verification: ImageArchive used to create every extracted file
    /// with FileManager's default permissions, silently discarding the
    /// tarball entry's own executable bit. Every prior unpacking test
    /// used plain text content, so this never surfaced until an actual
    /// exec attempt against a freshly pulled bundle failed with "binary
    /// not found or not executable." See DEBUGGING_LOG.md.
    func testUnpackPreservesExecutablePermission() throws {
        let tarball = workDirectory.appendingPathComponent("executable.tar.gz")
        let rootfs = workDirectory.appendingPathComponent("rootfs")

        try TarballFixture.write(
            entries: [
                TarballFixture.Entry(path: "app.sh", content: "#!/bin/sh\necho hi\n", permissions: 0o755)
            ],
            to: tarball
        )

        try ImageArchive.unpack(tarball: tarball, into: rootfs)

        let extractedPath = rootfs.appendingPathComponent("app.sh").path
        XCTAssertTrue(
            FileManager.default.isExecutableFile(atPath: extractedPath),
            "extracted file must keep the executable bit recorded in the tarball entry"
        )
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

    /// Writes a small, real, executable shell script into `directory` at
    /// `relativePath` and returns it. Used to give POSIXIsolationEngine a
    /// genuine binary to run, rather than mocking process execution.
    private func writeExecutableScript(_ contents: String, at relativePath: String, in directory: URL) throws -> URL {
        let scriptURL = directory.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: scriptURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        return scriptURL
    }

    /// Compiles a tiny real C program into `directory` at `relativePath`
    /// and returns it, by shelling out to the system's own clang. Used
    /// specifically where a genuinely compiled Mach-O binary is required
    /// rather than a shebang script - see JobSigner's own documentation
    /// and DEBUGGING_LOG.md #13 for why that distinction matters.
    private func compileTinyBinary(at relativePath: String, in directory: URL) throws -> URL {
        let sourceURL = directory.appendingPathComponent(relativePath + ".c")
        let binaryURL = directory.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: binaryURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "#include <unistd.h>\nint main(void) { sleep(3); return 0; }\n".write(
            to: sourceURL,
            atomically: true,
            encoding: .utf8
        )

        let clang = Process()
        clang.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
        clang.arguments = ["-o", binaryURL.path, sourceURL.path]
        try clang.run()
        clang.waitUntilExit()
        XCTAssertEqual(clang.terminationStatus, 0, "clang failed to compile the test fixture binary")

        return binaryURL
    }

    /// The core positive case for POSIXIsolationEngine: a real script
    /// inside the rootfs actually runs, and its real stdout is captured
    /// correctly. This proves spawn() returns a Process the caller can
    /// still attach a pipe to before launching, not one already running.
    func testPOSIXEngineRunsRealScriptAndCapturesOutput() throws {
        let rootfs = workDirectory.appendingPathComponent("rootfs")
        _ = try writeExecutableScript(
            "#!/bin/sh\necho hello-from-sandboxed-binary\n",
            at: "app.sh",
            in: rootfs
        )

        let config = ExecConfig(binaryPath: "/app.sh", rootfsPath: rootfs.path)
        let process = try POSIXIsolationEngine().spawn(config, rootfs: rootfs)

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        try process.run()
        process.waitUntilExit()

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: outputData, encoding: .utf8)
        XCTAssertEqual(output, "hello-from-sandboxed-binary\n")
        XCTAssertEqual(process.terminationStatus, 0)
    }

    /// A binary path using ".." to walk outside the rootfs must be
    /// rejected before any process is even configured, the same
    /// component-based check ImageArchive uses for tarball entries.
    func testPOSIXEngineRejectsPathTraversalBinaryPath() throws {
        let rootfs = workDirectory.appendingPathComponent("rootfs")
        try FileManager.default.createDirectory(at: rootfs, withIntermediateDirectories: true)

        let config = ExecConfig(binaryPath: "../../../../bin/sh", rootfsPath: rootfs.path)

        XCTAssertThrowsError(try POSIXIsolationEngine().spawn(config, rootfs: rootfs)) { error in
            guard case IsolationError.binaryEscapesRootfs = error else {
                XCTFail("expected binaryEscapesRootfs, got \(error)")
                return
            }
        }
    }

    /// The real escape attempt: a symlink planted inside the rootfs that
    /// points at a script living genuinely outside of it. If
    /// resolveBinaryPath only checked the raw, unresolved string, this
    /// would incorrectly appear to be a safe, in-rootfs path. Because it
    /// resolves symlinks before checking the rootfs prefix, this must
    /// still be rejected.
    func testPOSIXEngineRejectsSymlinkEscapingRootfs() throws {
        let rootfs = workDirectory.appendingPathComponent("rootfs")
        try FileManager.default.createDirectory(at: rootfs, withIntermediateDirectories: true)

        let outsideScript = try writeExecutableScript(
            "#!/bin/sh\necho this-should-never-run\n",
            at: "outside-script.sh",
            in: workDirectory
        )

        let symlinkPath = rootfs.appendingPathComponent("evil-link")
        try FileManager.default.createSymbolicLink(at: symlinkPath, withDestinationURL: outsideScript)

        let config = ExecConfig(binaryPath: "/evil-link", rootfsPath: rootfs.path)

        XCTAssertThrowsError(try POSIXIsolationEngine().spawn(config, rootfs: rootfs)) { error in
            guard case IsolationError.binaryEscapesRootfs = error else {
                XCTFail("expected binaryEscapesRootfs, got \(error)")
                return
            }
        }
    }

    /// A binaryPath that simply does not exist inside the rootfs (no
    /// traversal attempt involved, just a typo or a missing file) should
    /// fail with a distinct, honest error rather than being confused with
    /// an escape attempt.
    func testPOSIXEngineRejectsMissingBinary() throws {
        let rootfs = workDirectory.appendingPathComponent("rootfs")
        try FileManager.default.createDirectory(at: rootfs, withIntermediateDirectories: true)

        let config = ExecConfig(binaryPath: "/does-not-exist", rootfsPath: rootfs.path)

        XCTAssertThrowsError(try POSIXIsolationEngine().spawn(config, rootfs: rootfs)) { error in
            guard case IsolationError.binaryNotFound = error else {
                XCTFail("expected binaryNotFound, got \(error)")
                return
            }
        }
    }

    /// The real, load-bearing claim behind ResourceLimits: a process that
    /// spins forever must actually be killed by the kernel once its CPU
    /// time limit is exceeded, not merely have a limit "set" that does
    /// nothing. SIGXCPU is signal 24 on Darwin, and a process killed by a
    /// signal reports terminationStatus equal to that signal number with
    /// terminationReason .uncaughtSignal.
    func testCPULimitIsGenuinelyEnforcedByTheKernel() throws {
        let rootfs = workDirectory.appendingPathComponent("rootfs")
        _ = try writeExecutableScript(
            "#!/bin/sh\nwhile true; do :; done\n",
            at: "spin.sh",
            in: rootfs
        )

        let config = ExecConfig(binaryPath: "/spin.sh", rootfsPath: rootfs.path, cpuLimit: 1)
        let process = try POSIXIsolationEngine().spawn(config, rootfs: rootfs)

        try process.run()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationReason, .uncaughtSignal)
        XCTAssertEqual(process.terminationStatus, 24, "expected SIGXCPU (24), the kernel's real CPU-limit-exceeded signal")
    }

    /// When no limits are requested at all, spawn() should not route the
    /// process through the /bin/sh wrapper - the simple, common case
    /// should stay simple, with the binary launched directly.
    func testNoResourceLimitsMeansNoShellWrapping() throws {
        let rootfs = workDirectory.appendingPathComponent("rootfs")
        _ = try writeExecutableScript("#!/bin/sh\necho plain\n", at: "app.sh", in: rootfs)

        let config = ExecConfig(binaryPath: "/app.sh", rootfsPath: rootfs.path, cpuLimit: nil, memoryLimitMB: nil)
        let process = try POSIXIsolationEngine().spawn(config, rootfs: rootfs)

        // Compare the last path component and confirm it is not /bin/sh,
        // rather than exact URL equality against a path built without
        // going through RealPath's realpath()-based canonicalization -
        // process.executableURL is now the true canonical path (see
        // RealPath.swift), which can legitimately differ in string form
        // (e.g. /private/var/folders/... vs /var/folders/...) from a
        // path built with plain appendingPathComponent, without that
        // meaning anything went wrong.
        XCTAssertEqual(process.executableURL?.lastPathComponent, "app.sh")
        XCTAssertNotEqual(process.executableURL?.lastPathComponent, "sh")
    }

    /// A memory limit request must not crash or throw - it should still
    /// run the process, just without the (unenforceable on this
    /// platform) memory cap actually applied. See ResourceLimits.swift
    /// for why this is a deliberate, documented gap rather than a bug.
    func testMemoryLimitRequestDoesNotPreventExecution() throws {
        let rootfs = workDirectory.appendingPathComponent("rootfs")
        _ = try writeExecutableScript("#!/bin/sh\necho still-runs\n", at: "app.sh", in: rootfs)

        let config = ExecConfig(binaryPath: "/app.sh", rootfsPath: rootfs.path, memoryLimitMB: 64)
        let process = try POSIXIsolationEngine().spawn(config, rootfs: rootfs)

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        try process.run()
        process.waitUntilExit()

        let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        XCTAssertEqual(output, "still-runs\n")
        XCTAssertEqual(process.terminationStatus, 0)
    }

    /// The core positive case for SeatbeltIsolationEngine: a real script
    /// runs under sandbox-exec and its real stdout is captured through an
    /// anonymous Pipe. This specifically settles a question that could
    /// not be tested from a plain shell command while building this
    /// profile: whether a sandboxed process can write to an inherited,
    /// path-less pipe file descriptor without an explicit file-write*
    /// rule for it. It can - Seatbelt's file-read*/file-write* rules
    /// gate path-based opens, not writes to an fd the process already
    /// had inherited across fork/exec.
    func testSeatbeltEngineRunsRealScriptAndCapturesOutputThroughAPipe() throws {
        let rootfs = workDirectory.appendingPathComponent("rootfs")
        _ = try writeExecutableScript(
            "#!/bin/sh\necho hello-from-the-real-sandbox\n",
            at: "app.sh",
            in: rootfs
        )

        let config = ExecConfig(binaryPath: "/app.sh", rootfsPath: rootfs.path)
        let process = try SeatbeltIsolationEngine().spawn(config, rootfs: rootfs)

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        try process.run()
        process.waitUntilExit()

        let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        XCTAssertEqual(output, "hello-from-the-real-sandbox\n")
        XCTAssertEqual(process.terminationStatus, 0)
    }

    /// The real differentiator between this backend and
    /// POSIXIsolationEngine: a script that tries to write a file entirely
    /// outside its rootfs must be blocked by the kernel while it is
    /// running, not merely have its starting binary path checked once.
    /// POSIXIsolationEngine cannot stop this at all (see the earlier
    /// conversation on what is lost when falling back to it); a real
    /// Seatbelt profile must.
    func testSeatbeltEngineBlocksWritesOutsideRootfsWhileRunning() throws {
        let rootfs = workDirectory.appendingPathComponent("rootfs")
        let escapeTarget = workDirectory.appendingPathComponent("escaped-write-attempt.txt")
        _ = try writeExecutableScript(
            """
            #!/bin/sh
            if echo leaked > "$1" 2>/dev/null; then
                echo ESCAPE_SUCCEEDED
            else
                echo ESCAPE_BLOCKED
            fi
            """,
            at: "probe.sh",
            in: rootfs
        )

        let config = ExecConfig(binaryPath: "/probe.sh", arguments: [escapeTarget.path], rootfsPath: rootfs.path)
        let process = try SeatbeltIsolationEngine().spawn(config, rootfs: rootfs)

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        try process.run()
        process.waitUntilExit()

        let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        XCTAssertEqual(output, "ESCAPE_BLOCKED\n")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: escapeTarget.path),
            "the kernel must have blocked this write; POSIXIsolationEngine could not have stopped it"
        )
    }

    /// Same path-jail check as POSIXIsolationEngine, since both backends
    /// share BinaryPathResolver - confirms the shared resolver actually
    /// gets used here too, not bypassed.
    func testSeatbeltEngineRejectsPathTraversalBinaryPath() throws {
        let rootfs = workDirectory.appendingPathComponent("rootfs")
        try FileManager.default.createDirectory(at: rootfs, withIntermediateDirectories: true)

        let config = ExecConfig(binaryPath: "../../../../bin/sh", rootfsPath: rootfs.path)

        XCTAssertThrowsError(try SeatbeltIsolationEngine().spawn(config, rootfs: rootfs)) { error in
            guard case IsolationError.binaryEscapesRootfs = error else {
                XCTFail("expected binaryEscapesRootfs, got \(error)")
                return
            }
        }
    }

    /// The one ProcessSupervisor behavior that could not be exercised
    /// during manual end-to-end testing, because that test's process
    /// happened to die cleanly from SIGTERM alone: a process that
    /// deliberately ignores SIGTERM (via `trap '' TERM`) must still be
    /// killed once the grace period elapses, via a real SIGKILL. Uses a
    /// short 1-second gracePeriodSeconds override rather than the real 5
    /// second production default, so this test doesn't have to wait that
    /// long to prove the same behavior.
    func testStopEscalatesToSIGKILLWhenProcessIgnoresSIGTERM() async throws {
        let rootfs = workDirectory.appendingPathComponent("rootfs")
        _ = try writeExecutableScript(
            """
            #!/bin/sh
            trap '' TERM
            while true; do sleep 0.1; done
            """,
            at: "stubborn.sh",
            in: rootfs
        )

        let config = ExecConfig(binaryPath: "/stubborn.sh", rootfsPath: rootfs.path, isolated: false)
        let state = DaemonState()

        let startResponse = await ProcessSupervisor.start(config, state: state)
        guard case .jobStarted(let jobID) = startResponse else {
            XCTFail("expected jobStarted, got \(startResponse)")
            return
        }

        // Give the script a moment to actually start and install its trap
        // before sending SIGTERM.
        try await Task.sleep(nanoseconds: 300_000_000)

        let stopResponse = await ProcessSupervisor.stop(jobID: jobID, state: state, gracePeriodSeconds: 1)
        guard case .stopped = stopResponse else {
            XCTFail("expected stopped, got \(stopResponse)")
            return
        }

        // Wait past the 1 second grace period, plus a buffer for the
        // SIGKILL to actually land and the termination handler to run.
        try await Task.sleep(nanoseconds: 2_000_000_000)

        let finalState = await state.state(ofJob: jobID)
        XCTAssertEqual(finalState, .killed)

        let exitCode = await state.exitCode(ofJob: jobID)
        XCTAssertEqual(exitCode, SIGKILL, "the process should have been killed with SIGKILL after ignoring SIGTERM")
    }

    /// Proves JobSigner actually works through the real, full pipeline -
    /// not the standalone probe scripts used to work out the design in
    /// the first place. A genuinely compiled binary, spawned the normal
    /// way through ProcessSupervisor, must be inspectable via
    /// task_for_pid afterward. Uses isolated: false (the POSIX backend)
    /// since signing behavior itself doesn't depend on which isolation
    /// backend was used; BinaryPathResolver signs the binary the same
    /// way regardless.
    func testJobSignerMakesARealSpawnedBinaryInspectable() async throws {
        let rootfs = workDirectory.appendingPathComponent("rootfs")
        let binaryURL = try compileTinyBinary(at: "sleeper", in: rootfs)

        let config = ExecConfig(binaryPath: "/" + binaryURL.lastPathComponent, rootfsPath: rootfs.path, isolated: false)
        let state = DaemonState()

        let response = await ProcessSupervisor.start(config, state: state)
        guard case .jobStarted(let jobID) = response else {
            XCTFail("expected jobStarted, got \(response)")
            return
        }

        // Give the process a moment to actually be running before probing it.
        try await Task.sleep(nanoseconds: 300_000_000)

        guard let process = await state.process(forJob: jobID) else {
            XCTFail("expected a running process for job \(jobID)")
            return
        }

        var task: task_t = 0
        let kr = task_for_pid(mach_task_self_, process.processIdentifier, &task)
        XCTAssertEqual(kr, KERN_SUCCESS, "JobSigner should have made this compiled binary inspectable via task_for_pid")

        process.terminate()
    }
}
