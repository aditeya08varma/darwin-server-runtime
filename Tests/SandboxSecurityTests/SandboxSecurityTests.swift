// Security-focused tests for ImageStore (path traversal, signature
// verification) and Isolation (sandbox escape attempts). Stage 0 only has a
// smoke test; the real security tests described in the plan are added
// alongside their features in Stages 2 and 3.
import XCTest
@testable import ImageStore
@testable import Isolation

final class SandboxSecurityTests: XCTestCase {
    /// Checks that both ImageStore and Isolation report their placeholder
    /// status strings. Exists only to prove this test target builds and can
    /// see both modules before real security tests are written in Stages 2 and 3.
    func testPlaceholderModulesAreReachable() {
        XCTAssertFalse(ImageStore.status().isEmpty)
        XCTAssertFalse(Isolation.status().isEmpty)
    }
}
