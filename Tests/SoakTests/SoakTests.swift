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

    /// Polls for `markerURL` to exist, up to `timeout` seconds. Used
    /// instead of a fixed-duration sleep to wait for a fixture process to
    /// reach a specific point in its own execution (like "finished
    /// allocating and touching memory"). A fixed sleep cannot reliably
    /// do this: under real system load - like running the rest of this
    /// test suite at the same time - a duration that's comfortably long
    /// on an idle machine can be too short, which is exactly what caused
    /// this test to flake under full-suite runs before this fix. See
    /// DEBUGGING_LOG.md.
    private func waitForReadyMarker(at markerURL: URL, timeout: TimeInterval = 5) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !FileManager.default.fileExists(atPath: markerURL.path) {
            if Date() > deadline {
                XCTFail("timed out waiting for ready marker at \(markerURL.path)")
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// The core positive case: a real program that allocates and touches
    /// a known, sizable chunk of memory, signed the same way a real job
    /// would be, reports real, sane numbers back through
    /// MachMetricsSampler - not zero, not garbage.
    func testSampleReportsRealMemoryAndCPUUsage() async throws {
        let readyMarkerURL = workDirectory.appendingPathComponent("ready")
        let process = try compileAndRun(
            """
            #include <unistd.h>
            #include <string.h>
            #include <stdlib.h>
            #include <stdio.h>
            int main(void) {
                size_t size = 20 * 1024 * 1024;
                char *block = malloc(size);
                memset(block, 1, size);
                FILE *marker = fopen("\(readyMarkerURL.path)", "w");
                fclose(marker);
                sleep(5);
                return 0;
            }
            """,
            signed: true
        )
        defer {
            process.terminate()
            process.waitUntilExit()
        }

        // Wait for the fixture to actually finish allocating and
        // touching its memory, not just for some guessed amount of time
        // to pass.
        try await waitForReadyMarker(at: readyMarkerURL)

        let metrics = try MachMetricsSampler.sample(pid: process.processIdentifier)

        // 20MB was allocated and fully touched (memset, not just
        // malloc'd), so real memory usage should land close to that
        // number, not just "more than a small amount." This range check
        // (18-30MB, not just ">5MB") is deliberately tight: a loose
        // "greater than 5MB" threshold is exactly what let a real bug
        // slip through here before - task_info's resident_size field
        // reported well under 1MB for this same 20MB allocation and
        // still would have passed a >5MB check, while phys_footprint
        // (what this now reads) correctly lands in this range. See
        // DEBUGGING_LOG.md #15.
        XCTAssertGreaterThan(metrics.residentBytes, 18 * 1024 * 1024)
        XCTAssertLessThan(metrics.residentBytes, 30 * 1024 * 1024)
        XCTAssertGreaterThanOrEqual(metrics.userTimeSeconds, 0)
        XCTAssertGreaterThanOrEqual(metrics.systemTimeSeconds, 0)
    }

    /// The negative case that makes the positive one meaningful: a
    /// program that was never signed by JobSigner must fail to sample,
    /// with the specific error naming the real cause, confirming
    /// task_for_pid is genuinely gating this rather than the whole thing
    /// silently no-op'ing into success for any PID handed to it.
    func testSampleFailsForUnsignedBinary() async throws {
        let readyMarkerURL = workDirectory.appendingPathComponent("ready")
        let process = try compileAndRun(
            """
            #include <unistd.h>
            #include <stdio.h>
            int main(void) {
                FILE *marker = fopen("\(readyMarkerURL.path)", "w");
                fclose(marker);
                sleep(5);
                return 0;
            }
            """,
            signed: false
        )
        defer {
            process.terminate()
            process.waitUntilExit()
        }

        try await waitForReadyMarker(at: readyMarkerURL)

        XCTAssertThrowsError(try MachMetricsSampler.sample(pid: process.processIdentifier)) { error in
            guard case MachMetricsError.taskForPidFailed = error else {
                XCTFail("expected taskForPidFailed, got \(error)")
                return
            }
        }
    }
}
