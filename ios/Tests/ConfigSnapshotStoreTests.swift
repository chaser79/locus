import CryptoKit
import XCTest
#if canImport(Locus)
@testable import Locus
#elseif canImport(locus)
@testable import locus
#endif

final class ConfigSnapshotStoreTests: XCTestCase {
    func testUnavailableApplicationSupportFailsClosedWithoutTemporaryFallback() {
        let store = SecureConfigSnapshotStore(fileURL: nil)

        let snapshot = store.read()

        XCTAssertEqual(snapshot.status, .corrupt)
        XCTAssertTrue(snapshot.values.isEmpty)
        XCTAssertNotNil(snapshot.error)
        XCTAssertThrowsError(try store.write(["distanceFilter": 25]))
    }

    private let key = SymmetricKey(data: Data(repeating: 7, count: 32))

    func testEncryptedRoundTripPreservesNestedNullWithoutPlaintextLeak() throws {
        let fixture = try makeFixture()
        let store = makeStore(fixture)
        let config: [String: Any] = [
            "headers": ["Authorization": "Bearer top-secret"],
            "extras": ["nullable": NSNull(), "nested": [1, 2, 3]],
            "stopOnTerminate": false,
        ]

        try store.write(config)

        let encrypted = try Data(contentsOf: fixture.fileURL)
        XCTAssertNil(String(data: encrypted, encoding: .utf8)?.range(of: "top-secret"))
        let restored = store.read()
        XCTAssertEqual(restored.status, .valid)
        XCTAssertTrue((restored.values["extras"] as? [String: Any])?["nullable"] is NSNull)
        XCTAssertEqual(restored.values["stopOnTerminate"] as? Bool, false)
    }

    func testLegacyPlaintextIsRemovedOnlyAfterEncryptedWrite() throws {
        let fixture = try makeFixture()
        fixture.defaults.set(
            ["headers": ["Authorization": "Bearer legacy"]],
            forKey: ConfigManager.lastConfigKey
        )
        let store = makeStore(fixture)

        let legacy = store.read()
        XCTAssertEqual(legacy.status, .valid)
        XCTAssertTrue(legacy.isLegacyPlaintext)
        XCTAssertNotNil(fixture.defaults.dictionary(forKey: ConfigManager.lastConfigKey))

        try store.write(legacy.values)

        XCTAssertNil(fixture.defaults.object(forKey: ConfigManager.lastConfigKey))
        XCTAssertEqual(store.read().status, .valid)
    }

    func testTamperedSnapshotFailsClosed() throws {
        let fixture = try makeFixture()
        let store = makeStore(fixture)
        try store.write(["distanceFilter": 10])
        var encrypted = try Data(contentsOf: fixture.fileURL)
        encrypted[encrypted.startIndex] ^= 0xff
        try encrypted.write(to: fixture.fileURL)

        let restored = store.read()

        XCTAssertEqual(restored.status, .corrupt)
        XCTAssertTrue(restored.values.isEmpty)
    }

    func testPartialMergePreservesConfigAndPrivacyGuard() {
        let merged = SecureConfigSnapshotStore.merge(
            current: [
                "distanceFilter": 25,
                "privacyModeEnabled": true,
                "notification": ["title": "Old", "text": "Keep"],
            ],
            incoming: [
                "notification": ["title": "New"],
            ]
        )

        XCTAssertEqual(merged["distanceFilter"] as? Int, 25)
        XCTAssertEqual(merged["privacyModeEnabled"] as? Bool, true)
        let notification = merged["notification"] as? [String: Any]
        XCTAssertEqual(notification?["title"] as? String, "New")
        XCTAssertEqual(notification?["text"] as? String, "Keep")
    }

    private func makeStore(_ fixture: Fixture) -> SecureConfigSnapshotStore {
        SecureConfigSnapshotStore(
            fileURL: fixture.fileURL,
            userDefaults: fixture.defaults,
            keyProvider: { self.key }
        )
    }

    private func makeFixture() throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("locus-config-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suiteName = "dev.locus.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        return Fixture(
            fileURL: directory.appendingPathComponent("snapshot"),
            defaults: defaults
        )
    }

    private struct Fixture {
        let fileURL: URL
        let defaults: UserDefaults
    }
}

final class ConfigManagerPersistenceTests: XCTestCase {
    private final class InMemoryStore: ConfigSnapshotStoring {
        var snapshot: PersistedConfigSnapshot = .absent
        var writeError: Error?

        func read() -> PersistedConfigSnapshot { snapshot }

        func write(_ values: [String: Any]) throws {
            if let writeError { throw writeError }
            guard JSONSerialization.isValidJSONObject(values) else {
                throw ConfigSnapshotError.invalidJSON
            }
            snapshot = PersistedConfigSnapshot(
                status: .valid,
                values: values,
                isLegacyPlaintext: false,
                error: nil
            )
        }
    }

    func testMissingLegacyFlagsKeepDocumentedDefaults() throws {
        let defaults = try makeDefaults()
        let manager = ConfigManager(snapshotStore: InMemoryStore(), userDefaults: defaults)

        XCTAssertTrue(manager.stopOnTerminate)
        XCTAssertFalse(manager.startOnBoot)
        XCTAssertFalse(manager.enableHeadless)
    }

    func testExplicitLegacyFlagsRemainBackwardsCompatible() throws {
        let defaults = try makeDefaults()
        defaults.set(false, forKey: ConfigManager.stopOnTerminateKey)
        defaults.set(true, forKey: ConfigManager.startOnBootKey)

        let manager = ConfigManager(snapshotStore: InMemoryStore(), userDefaults: defaults)

        XCTAssertFalse(manager.stopOnTerminate)
        XCTAssertTrue(manager.startOnBoot)
    }

    func testEncryptedSnapshotOverridesConflictingLegacyFlags() throws {
        let defaults = try makeDefaults()
        defaults.set(true, forKey: ConfigManager.stopOnTerminateKey)
        defaults.set(false, forKey: ConfigManager.enableHeadlessKey)
        let store = InMemoryStore()
        store.snapshot = PersistedConfigSnapshot(
            status: .valid,
            values: ["stopOnTerminate": false, "enableHeadless": true],
            isLegacyPlaintext: false,
            error: nil
        )

        let manager = ConfigManager(snapshotStore: store, userDefaults: defaults)

        XCTAssertFalse(manager.stopOnTerminate)
        XCTAssertTrue(manager.enableHeadless)
    }

    func testPrivacyGuardRemainsEnabledWhenDisableCannotPersist() throws {
        let defaults = try makeDefaults()
        let store = InMemoryStore()
        let manager = ConfigManager(snapshotStore: store, userDefaults: defaults)
        try manager.apply(["distanceFilter": 10])
        try manager.setPrivacyMode(true)
        store.writeError = ConfigSnapshotError.invalidJSON

        XCTAssertThrowsError(try manager.setPrivacyMode(false))
        XCTAssertTrue(manager.privacyModeEnabled)
        XCTAssertEqual(store.snapshot.values["privacyModeEnabled"] as? Bool, true)
    }

    func testInvalidConfigFailsWithoutMutatingCurrentConfig() throws {
        let defaults = try makeDefaults()
        let store = InMemoryStore()
        let manager = ConfigManager(snapshotStore: store, userDefaults: defaults)
        try manager.apply(["distanceFilter": 25])

        XCTAssertThrowsError(try manager.apply(["extras": ["date": Date()]]))
        XCTAssertEqual(manager.distanceFilter, 25)
        XCTAssertNil(manager.persistedConfig["extras"])
    }

    private func makeDefaults() throws -> UserDefaults {
        let suiteName = "dev.locus.config-manager-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return defaults
    }
}
