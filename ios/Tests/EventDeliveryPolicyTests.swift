import XCTest
#if canImport(Locus)
@testable import Locus
#elseif canImport(locus)
@testable import locus
#endif

final class EventDeliveryPolicyTests: XCTestCase {
    func testGuardedRawLocationIsSuppressedWithoutLiveEngine() {
        XCTAssertEqual(
            eventDeliveryRoute(
                hasEventSink: false,
                containsRawLocation: true,
                privacyGuardEnabled: true
            ),
            .suppressed
        )
    }

    func testGuardedRawLocationStillReachesUIPrivacyFilter() {
        XCTAssertEqual(
            eventDeliveryRoute(
                hasEventSink: true,
                containsRawLocation: true,
                privacyGuardEnabled: true
            ),
            .eventSink
        )
    }

    func testUnguardedRawLocationKeepsHeadlessDelivery() {
        XCTAssertEqual(
            eventDeliveryRoute(
                hasEventSink: false,
                containsRawLocation: true,
                privacyGuardEnabled: false
            ),
            .headless
        )
    }

    func testNonLocationEventKeepsHeadlessDeliveryWhileGuarded() {
        XCTAssertEqual(
            eventDeliveryRoute(
                hasEventSink: false,
                containsRawLocation: false,
                privacyGuardEnabled: true
            ),
            .headless
        )
    }
}
