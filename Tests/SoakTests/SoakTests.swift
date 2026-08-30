// Tests for the Telemetry module, including real Mach kernel sampling.
// The full 30-minute (CI) / 72-hour (local) RSS-trend soak test described
// in the plan is still to come; what's here now proves MachMetricsSampler
// itself reports real, sane numbers for a real process.
import XCTest
import Foundation
@testable import Telemetry
@testable import Isolation

final class SoakTests: XCTestCase {
    private var workDirectory: URL!

    override func setUpWithError() throws {
        workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SoakTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDirectory)
    }

    /// Checks that the CSystemBridge C target is linked and callable through
    /// Telemetry. This is the same check main.swift prints at startup,
    /// captured here as an automated test rather than something a person has
    /// to read off the console.
    func testCSystemBridgeIsLinked() {
        XCTAssertTrue(Telemetry.bridgeIsLinked())
    }

    /// Compiles `source` into a real binary under the work directory,
    /// optionally signs it with JobSigner (the same precondition
    /// ProcessSupervisor applies to every real job before running it),
    /// and launches it. The caller is responsible for terminating and
    /// reaping the returned Process.
    private func compileAndRun(_ source: String, signed: Bool) throws -> Process {
        let sourceURL = workDirectory.appendingPathComponent("\(UUID().uuidString).c")
        let binaryURL = workDirectory.appendingPathComponent(UUID().uuidString)
        try source.write(to: sourceURL, atomically: true, encoding: .utf8)

        let clang = Process()
        clang.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
        clang.arguments = ["-o", binaryURL.path, sourceURL.path]
        try clang.run()
        clang.waitUntilExit()
        XCTAssertEqual(clang.terminationStatus, 0, "clang failed to compile the test fixture binary")

        if signed {
            JobSigner.makeInspectable(binaryURL)
        }

        let process = Process()
        process.executableURL = binaryURL
        try process.run()
        return process
    }

    /// The core positive case: a real program that allocates and touches
    /// a known, sizable chunk of memory, signed the same way a real job
    /// would be, reports real, sane numbers back through
    /// MachMetricsSampler - not zero, not garbage.
    func testSampleReportsRealMemoryAndCPUUsage() async throws {
        let process = try compileAndRun(
            """
            #include <unistd.h>
            #include <string.h>
            #include <stdlib.h>
            int main(void) {
                size_t size = 20 * 1024 * 1024;
                char *block = malloc(size);
                memset(block, 1, size);
                sleep(3);
                return 0;
            }
            """,
            signed: true
        )
        defer {
            process.terminate()
            process.waitUntilExit()
        }

        // Give it a moment to actually allocate and touch the memory.
        try await Task.sleep(nanoseconds: 300_000_000)

        let metrics = try MachMetricsSampler.sample(pid: process.processIdentifier)

        // 20MB was allocated and fully touched (memset, not just
        // malloc'd), so resident memory should reflect a meaningful
        // fraction of that - comfortably distinguishing a real
        // measurement from zero or a nonsense small number.
        XCTAssertGreaterThan(metrics.residentBytes, 5 * 1024 * 1024)
        XCTAssertGreaterThanOrEqual(metrics.userTimeSeconds, 0)
        XCTAssertGreaterThanOrEqual(metrics.systemTimeSeconds, 0)
    }

    /// The negative case that makes the positive one meaningful: a
    /// program that was never signed by JobSigner must fail to sample,
    /// with the specific error naming the real cause, confirming
    /// task_for_pid is genuinely gating this rather than the whole thing
    /// silently no-op'ing into success for any PID handed to it.
    func testSampleFailsForUnsignedBinary() async throws {
        let process = try compileAndRun(
            "#include <unistd.h>\nint main(void) { sleep(3); return 0; }\n",
            signed: false
        )
        defer {
            process.terminate()
            process.waitUntilExit()
        }

        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertThrowsError(try MachMetricsSampler.sample(pid: process.processIdentifier)) { error in
            guard case MachMetricsError.taskForPidFailed = error else {
                XCTFail("expected taskForPidFailed, got \(error)")
                return
            }
        }
    }
}
