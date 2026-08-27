// Long-running leak-detection tests for the Telemetry module. Stage 0 only
// has a smoke test; the real 30-minute (CI) / 72-hour (local) RSS-trend soak
// test described in the plan is added in Stage 4.
import XCTest
@testable import Telemetry

final class SoakTests: XCTestCase {
    /// Checks that the CSystemBridge C target is linked and callable through
    /// Telemetry. This is the same check main.swift prints at startup,
    /// captured here as an automated test rather than something a person has
    /// to read off the console.
    func testCSystemBridgeIsLinked() {
        XCTAssertTrue(Telemetry.bridgeIsLinked())
    }
}
