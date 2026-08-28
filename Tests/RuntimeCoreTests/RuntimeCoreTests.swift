// Tests for the RuntimeCore module: the version() smoke test from Stage 0,
// plus real coverage for IPCMessage/IPCResponse Codable round-tripping from
// Stage 1 onward. A "round trip" test encodes a value to JSON and decodes
// it straight back, then checks the result matches the original exactly.
// That's the same encode/decode path the CLI and daemon use for real, so
// this is directly testing the wire protocol they will actually speak.
import XCTest
@testable import RuntimeCore

final class RuntimeCoreTests: XCTestCase {
    /// Checks that RuntimeCore.version() returns a non-empty string.
    /// This is deliberately trivial for Stage 0; it exists to prove the test
    /// target itself builds, links against RuntimeCore, and runs under `swift test`.
    func testVersionIsNotEmpty() {
        XCTAssertFalse(RuntimeCore.version().isEmpty)
    }

    /// Confirms the simplest message, .ping, survives a JSON encode/decode
    /// round trip. It carries no associated data, which exercises a
    /// different path through the compiler-generated Codable code than the
    /// cases with associated values do below.
    func testIPCMessagePingRoundTrips() throws {
        let data = try JSONEncoder().encode(IPCMessage.ping)
        let decoded = try JSONDecoder().decode(IPCMessage.self, from: data)
        XCTAssertEqual(IPCMessage.ping, decoded)
    }

    /// Confirms an .exec message, carrying a full ExecConfig, survives a
    /// round trip unchanged. This is the exact scenario that happens every
    /// time darwin-run sends a real exec request to the daemon in Stage 3.
    func testIPCMessageExecRoundTrips() throws {
        let config = ExecConfig(
            binaryPath: "/bin/echo",
            arguments: ["hello"],
            rootfsPath: "/tmp/job-root",
            cpuLimit: 2,
            memoryLimitMB: 256,
            isolated: true
        )
        let original = IPCMessage.exec(config)

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(IPCMessage.self, from: data)

        XCTAssertEqual(original, decoded)
    }

    /// Confirms an .jobStatus response round-trips correctly in both shapes
    /// it can take: exitCode present (job finished) and exitCode nil (job
    /// still running). Optional fields are a common source of Codable bugs,
    /// so both cases are worth checking explicitly rather than just one.
    func testIPCResponseJobStatusRoundTrips() throws {
        let running = IPCResponse.jobStatus(jobID: "abc-123", state: .running, exitCode: nil)
        let runningData = try JSONEncoder().encode(running)
        let decodedRunning = try JSONDecoder().decode(IPCResponse.self, from: runningData)
        XCTAssertEqual(running, decodedRunning)

        let exited = IPCResponse.jobStatus(jobID: "abc-123", state: .exited, exitCode: 0)
        let exitedData = try JSONEncoder().encode(exited)
        let decodedExited = try JSONDecoder().decode(IPCResponse.self, from: exitedData)
        XCTAssertEqual(exited, decodedExited)
    }
}
