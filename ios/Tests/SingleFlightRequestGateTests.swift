import XCTest
#if canImport(Locus)
@testable import Locus
#elseif canImport(locus)
@testable import locus
#endif

final class SingleFlightRequestGateTests: XCTestCase {
    private final class Owner {}

    func testRejectsOverlapUntilCompletion() {
        let gate = SingleFlightRequestGate()
        let first = Owner()
        let second = Owner()

        XCTAssertTrue(gate.begin(owner: first))
        XCTAssertFalse(gate.begin(owner: second))
        gate.complete()
        XCTAssertTrue(gate.begin(owner: second))
    }

    func testOnlyOwningDetachClearsRequest() {
        let gate = SingleFlightRequestGate()
        let first = Owner()
        let second = Owner()

        XCTAssertTrue(gate.begin(owner: first))
        XCTAssertFalse(gate.detach(owner: second))
        XCTAssertTrue(gate.detach(owner: first))
        XCTAssertTrue(gate.begin(owner: second))
    }
}
