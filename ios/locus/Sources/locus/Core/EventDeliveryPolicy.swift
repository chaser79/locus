import Foundation

enum EventDeliveryRoute: Equatable {
    case eventSink
    case headless
    case suppressed
}

/// A live UI engine receives raw locations because Dart owns zone-specific
/// exclusion and obfuscation. Headless callbacks have no restored zone graph,
/// so the durable native guard must fail closed until Dart releases it.
func eventDeliveryRoute(
    hasEventSink: Bool,
    containsRawLocation: Bool,
    privacyGuardEnabled: Bool
) -> EventDeliveryRoute {
    if hasEventSink { return .eventSink }
    if containsRawLocation && privacyGuardEnabled { return .suppressed }
    return .headless
}
