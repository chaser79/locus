import Foundation

enum TrackingRecoveryAction: Equatable {
    case none
    case keepRunning
    case waitForConfig
    case clearDesiredState
    case stopRuntime
    case start
}

func decideTrackingRecovery(
    trackingDesired: Bool,
    runtimeEnabled: Bool,
    configStatus: PersistedConfigStatus,
    hasAlwaysAuthorization: Bool,
    locationServicesEnabled: Bool,
    stopOnTerminate: Bool
) -> TrackingRecoveryAction {
    if !trackingDesired && runtimeEnabled { return .stopRuntime }
    if !trackingDesired { return .none }
    if !hasAlwaysAuthorization || !locationServicesEnabled { return .clearDesiredState }
    if runtimeEnabled { return .keepRunning }
    if configStatus == .corrupt { return .waitForConfig }
    if stopOnTerminate { return .clearDesiredState }
    if configStatus == .absent { return .clearDesiredState }
    return .start
}
