import XCTest
#if canImport(Locus)
@testable import Locus
#elseif canImport(locus)
@testable import locus
#endif

final class TrackingRecoveryPolicyTests: XCTestCase {
    func testStoppedStateStopsStaleRuntime() {
        XCTAssertEqual(
            decideTrackingRecovery(
                trackingDesired: false,
                runtimeEnabled: true,
                configStatus: .valid,
                hasAlwaysAuthorization: true,
                locationServicesEnabled: true,
                stopOnTerminate: false
            ),
            .stopRuntime
        )
    }

    func testValidAlwaysAuthorizedDesiredStateStarts() {
        XCTAssertEqual(
            decideTrackingRecovery(
                trackingDesired: true,
                runtimeEnabled: false,
                configStatus: .valid,
                hasAlwaysAuthorization: true,
                locationServicesEnabled: true,
                stopOnTerminate: false
            ),
            .start
        )
    }

    func testStopOnTerminatePreventsColdRecovery() {
        XCTAssertEqual(
            decideTrackingRecovery(
                trackingDesired: true,
                runtimeEnabled: false,
                configStatus: .valid,
                hasAlwaysAuthorization: true,
                locationServicesEnabled: true,
                stopOnTerminate: true
            ),
            .clearDesiredState
        )
    }

    func testChangingStopOnTerminateDoesNotStopAHealthyRunningSession() {
        XCTAssertEqual(
            decideTrackingRecovery(
                trackingDesired: true,
                runtimeEnabled: true,
                configStatus: .valid,
                hasAlwaysAuthorization: true,
                locationServicesEnabled: true,
                stopOnTerminate: true
            ),
            .keepRunning
        )
    }

    func testRevokedPermissionClearsDesiredState() {
        XCTAssertEqual(
            decideTrackingRecovery(
                trackingDesired: true,
                runtimeEnabled: false,
                configStatus: .valid,
                hasAlwaysAuthorization: false,
                locationServicesEnabled: true,
                stopOnTerminate: false
            ),
            .clearDesiredState
        )
    }

    func testCorruptConfigWaitsWithoutStartingOrDiscardingIntent() {
        XCTAssertEqual(
            decideTrackingRecovery(
                trackingDesired: true,
                runtimeEnabled: false,
                configStatus: .corrupt,
                hasAlwaysAuthorization: true,
                locationServicesEnabled: true,
                stopOnTerminate: false
            ),
            .waitForConfig
        )
    }

    func testCorruptConfigDoesNotInheritStopOnTerminateDefault() {
        XCTAssertEqual(
            decideTrackingRecovery(
                trackingDesired: true,
                runtimeEnabled: false,
                configStatus: .corrupt,
                hasAlwaysAuthorization: true,
                locationServicesEnabled: true,
                stopOnTerminate: true
            ),
            .waitForConfig
        )
    }

    func testAbsentConfigClearsUnrecoverableLegacyIntent() {
        XCTAssertEqual(
            decideTrackingRecovery(
                trackingDesired: true,
                runtimeEnabled: false,
                configStatus: .absent,
                hasAlwaysAuthorization: true,
                locationServicesEnabled: true,
                stopOnTerminate: false
            ),
            .clearDesiredState
        )
    }
}
