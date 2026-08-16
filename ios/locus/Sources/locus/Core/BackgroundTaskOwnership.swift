import Foundation

/// Returns only identifiers that Locus configured or successfully registered.
/// Keeping this ownership rule pure makes it impossible for stopTracking to
/// broaden cancellation to background work owned by the host application.
func locusBackgroundTaskIdentifiers(
    configured: String,
    registered: Set<String>
) -> [String] {
    let configuredIdentifier = configured.trimmingCharacters(in: .whitespacesAndNewlines)
    var identifiers = registered.filter { !$0.isEmpty }
    if !configuredIdentifier.isEmpty {
        identifiers.insert(configuredIdentifier)
    }
    return identifiers.sorted()
}
