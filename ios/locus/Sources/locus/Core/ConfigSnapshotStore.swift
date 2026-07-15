import CryptoKit
import Foundation
import Security

enum PersistedConfigStatus: Equatable {
    case absent
    case valid
    case corrupt
}

struct PersistedConfigSnapshot {
    let status: PersistedConfigStatus
    let values: [String: Any]
    let isLegacyPlaintext: Bool
    let error: Error?

    static let absent = PersistedConfigSnapshot(
        status: .absent,
        values: [:],
        isLegacyPlaintext: false,
        error: nil
    )
}

protocol ConfigSnapshotStoring {
    func read() -> PersistedConfigSnapshot
    func write(_ values: [String: Any]) throws
}

enum ConfigSnapshotError: LocalizedError {
    case invalidJSON
    case invalidRoot
    case missingEncryptionKey
    case randomGeneration(OSStatus)
    case keychainWriteFailed
    case missingEncryptedPayload
    case storageDirectoryUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidJSON:
            return "Configuration contains a value that cannot be encoded as JSON"
        case .invalidRoot:
            return "Persisted configuration is not a JSON object"
        case .missingEncryptionKey:
            return "The configuration encryption key is unavailable"
        case let .randomGeneration(status):
            return "Unable to generate configuration encryption key (status: \(status))"
        case .keychainWriteFailed:
            return "Unable to store the configuration encryption key"
        case .missingEncryptedPayload:
            return "Unable to create the encrypted configuration payload"
        case .storageDirectoryUnavailable:
            return "Application Support is unavailable for configuration persistence"
        }
    }
}

/// Owns the durable recovery snapshot. The payload is AES-GCM encrypted on disk
/// and its device-local key is stored in Keychain. Existing UserDefaults data is
/// read only for migration and removed only after a verified encrypted write.
final class SecureConfigSnapshotStore: ConfigSnapshotStoring {
    static let encryptionKeyName = "config_snapshot_key_v1"
    static let directoryName = "dev.locus"
    static let fileName = "config_snapshot_v1"

    private let fileURL: URL?
    private let userDefaults: UserDefaults
    private let secureStorage: SecureStorage
    private let keyProvider: (() throws -> SymmetricKey)?
    private let legacyKey: String
    private let aad = Data("dev.locus.config_snapshot:v1".utf8)

    init(
        fileURL: URL? = SecureConfigSnapshotStore.defaultFileURL(),
        userDefaults: UserDefaults = .standard,
        secureStorage: SecureStorage = .shared,
        legacyKey: String = ConfigManager.lastConfigKey,
        keyProvider: (() throws -> SymmetricKey)? = nil
    ) {
        self.fileURL = fileURL
        self.userDefaults = userDefaults
        self.secureStorage = secureStorage
        self.legacyKey = legacyKey
        self.keyProvider = keyProvider
    }

    func read() -> PersistedConfigSnapshot {
        guard let fileURL else {
            return PersistedConfigSnapshot(
                status: .corrupt,
                values: [:],
                isLegacyPlaintext: false,
                error: ConfigSnapshotError.storageDirectoryUnavailable
            )
        }
        if FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                let encrypted = try Data(contentsOf: fileURL)
                guard let key = try loadExistingKey() else {
                    throw ConfigSnapshotError.missingEncryptionKey
                }
                let sealedBox = try AES.GCM.SealedBox(combined: encrypted)
                let cleartext = try AES.GCM.open(sealedBox, using: key, authenticating: aad)
                return try decode(cleartext, isLegacyPlaintext: false)
            } catch {
                return PersistedConfigSnapshot(
                    status: .corrupt,
                    values: [:],
                    isLegacyPlaintext: false,
                    error: error
                )
            }
        }

        guard let legacy = userDefaults.dictionary(forKey: legacyKey) else {
            return .absent
        }

        do {
            let data = try encode(legacy)
            return try decode(data, isLegacyPlaintext: true)
        } catch {
            return PersistedConfigSnapshot(
                status: .corrupt,
                values: [:],
                isLegacyPlaintext: true,
                error: error
            )
        }
    }

    func write(_ values: [String: Any]) throws {
        guard let fileURL else {
            throw ConfigSnapshotError.storageDirectoryUnavailable
        }
        let cleartext = try encode(values)
        let key = try loadOrCreateKey()
        let sealedBox = try AES.GCM.seal(cleartext, using: key, authenticating: aad)
        guard let encrypted = sealedBox.combined else {
            throw ConfigSnapshotError.missingEncryptedPayload
        }

        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try encrypted.write(to: fileURL, options: .atomic)
        protectSnapshotFile()

        // This is intentionally last: a failed encrypted write must leave the
        // legacy source intact for a future migration attempt.
        userDefaults.removeObject(forKey: legacyKey)
    }

    static func merge(
        current: [String: Any],
        incoming: [String: Any]
    ) -> [String: Any] {
        var merged = current
        for (key, value) in incoming {
            merged[key] = value
        }

        if let incomingNotification = incoming["notification"] as? [String: Any] {
            var notification = current["notification"] as? [String: Any] ?? [:]
            for (key, value) in incomingNotification {
                notification[key] = value
            }
            merged["notification"] = notification
        }

        return merged
    }

    static func defaultFileURL(fileManager: FileManager = .default) -> URL? {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
    }

    private func encode(_ values: [String: Any]) throws -> Data {
        guard JSONSerialization.isValidJSONObject(values) else {
            throw ConfigSnapshotError.invalidJSON
        }
        return try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])
    }

    private func decode(
        _ data: Data,
        isLegacyPlaintext: Bool
    ) throws -> PersistedConfigSnapshot {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let values = object as? [String: Any] else {
            throw ConfigSnapshotError.invalidRoot
        }
        return PersistedConfigSnapshot(
            status: .valid,
            values: values,
            isLegacyPlaintext: isLegacyPlaintext,
            error: nil
        )
    }

    private func loadExistingKey() throws -> SymmetricKey? {
        if let keyProvider {
            return try keyProvider()
        }
        guard let data = secureStorage.getData(forKey: Self.encryptionKeyName) else {
            return nil
        }
        guard data.count == 32 else {
            throw ConfigSnapshotError.missingEncryptionKey
        }
        return SymmetricKey(data: data)
    }

    private func loadOrCreateKey() throws -> SymmetricKey {
        if let existing = try loadExistingKey() {
            return existing
        }

        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw ConfigSnapshotError.randomGeneration(status)
        }
        let data = Data(bytes)
        guard secureStorage.setData(data, forKey: Self.encryptionKeyName) else {
            throw ConfigSnapshotError.keychainWriteFailed
        }
        return SymmetricKey(data: data)
    }

    private func protectSnapshotFile() {
        #if os(iOS)
        guard let fileURL else { return }
        do {
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: fileURL.path
            )
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutableURL = fileURL
            try mutableURL.setResourceValues(values)
        } catch {
            NSLog("[locus.ConfigSnapshot] Unable to apply file protection: %@", error.localizedDescription)
        }
        #endif
    }
}
