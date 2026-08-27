// Tests for the RuntimeCore module. Stage 0 only has a version() smoke test;
// Stage 1 adds real coverage for IPCMessage Codable round-tripping here.
import XCTest
@testable import RuntimeCore

final class RuntimeCoreTests: XCTestCase {
    /// Checks that RuntimeCore.version() returns a non-empty string.
    /// This is deliberately trivial for Stage 0; it exists to prove the test
    /// target itself builds, links against RuntimeCore, and runs under `swift test`.
    func testVersionIsNotEmpty() {
        XCTAssertFalse(RuntimeCore.version().isEmpty)
    }
}
