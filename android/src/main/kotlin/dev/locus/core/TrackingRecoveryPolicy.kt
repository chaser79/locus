package dev.locus.core

internal enum class TrackingRecoveryOrigin {
    FLUTTER_ENGINE,
    FOREGROUND_SERVICE,
}

internal enum class TrackingRecoveryAction {
    NONE,
    KEEP_RUNNING,
    WAIT_FOR_CONFIG,
    CLEAR_DESIRED_STATE,
    STOP_RUNTIME,
    START,
}

internal fun decideTrackingRecovery(
    trackingDesired: Boolean,
    runtimeEnabled: Boolean,
    configStatus: PersistedConfigStatus,
    hasPermission: Boolean,
): TrackingRecoveryAction = when {
    !trackingDesired && runtimeEnabled -> TrackingRecoveryAction.STOP_RUNTIME
    !trackingDesired -> TrackingRecoveryAction.NONE
    !hasPermission -> TrackingRecoveryAction.CLEAR_DESIRED_STATE
    runtimeEnabled -> TrackingRecoveryAction.KEEP_RUNNING
    configStatus == PersistedConfigStatus.CORRUPT -> TrackingRecoveryAction.WAIT_FOR_CONFIG
    configStatus == PersistedConfigStatus.ABSENT -> TrackingRecoveryAction.CLEAR_DESIRED_STATE
    else -> TrackingRecoveryAction.START
}
