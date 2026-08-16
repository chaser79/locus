import XCTest
#if canImport(Locus)
@testable import Locus
#elseif canImport(locus)
@testable import locus
#endif

final class BackgroundTaskOwnershipTests: XCTestCase {
    func testCancellationIdentifiersContainOnlyConfiguredAndRegisteredLocusTasks() {
        XCTAssertEqual(
            locusBackgroundTaskIdentifiers(
                configured: "  dev.locus.current  ",
                registered: ["dev.locus.previous", "dev.locus.current"]
            ),
            ["dev.locus.current", "dev.locus.previous"]
        )
    }

    func testBlankConfigurationDoesNotInventAnIdentifier() {
        XCTAssertEqual(
            locusBackgroundTaskIdentifiers(configured: "  ", registered: []),
            []
        )
    }
}
