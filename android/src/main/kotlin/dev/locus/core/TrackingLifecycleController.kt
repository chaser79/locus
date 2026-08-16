package dev.locus.core

import android.os.Build
import android.util.Log
import dev.locus.activity.MotionManager
import dev.locus.geofence.GeofenceManager
import dev.locus.location.LocationClient

internal enum class TrackingStartOrigin {
    STANDARD,
    FOREGROUND_SERVICE_RECOVERY,
}

class TrackingLifecycleController(
    private val config: ConfigManager,
    private val locationClient: LocationClient,
    private val motionManager: MotionManager,
    private val geofenceManager: GeofenceManager,
    private val foregroundServiceGateway: ForegroundServiceGateway,
    private val trackingEventEmitter: TrackingEventEmitter,
    private val logManager: LogManager,
    private val trackingStats: TrackingStats
) {
    internal fun start(
        origin: TrackingStartOrigin = TrackingStartOrigin.STANDARD,
        onComplete: (Boolean) -> Unit,
    ) {
        if (!locationClient.hasPermission()) {
            Log.w(TAG, "Location permission missing; tracking not started.")
            onComplete(false)
            return
        }

        val requiresForegroundService = shouldStartForegroundService(
            configured = config.foregroundService,
            supportedBySdk = Build.VERSION.SDK_INT >= Build.VERSION_CODES.O,
            origin = origin,
        )
        if (requiresForegroundService && !foregroundServiceGateway.start(config)) {
            onComplete(false)
            return
        }

        try {
            trackingStats.onTrackingStart()
            motionManager.start()
            locationClient.start registration@{ registered ->
                if (!registered) {
                    Log.e(TAG, "Location registration failed; rolling back tracking startup")
                    stop()
                    onComplete(false)
                    return@registration
                }

                try {
                    geofenceManager.startGeofencesInternal()
                    trackingEventEmitter.startProviderMonitoring()
                    trackingEventEmitter.emitProviderChange()
                    trackingEventEmitter.emitEnabledChange(true)
                    logManager.log("info", "start")
                    onComplete(true)
                } catch (error: RuntimeException) {
                    Log.e(TAG, "Tracking startup failed; rolling back partial runtime", error)
                    stop()
                    onComplete(false)
                }
            }
        } catch (error: RuntimeException) {
            Log.e(TAG, "Tracking startup failed; rolling back partial runtime", error)
            stop()
            onComplete(false)
        }
    }

    fun stop() {
        trackingStats.onTrackingStop()
        motionManager.stop()
        locationClient.stop()
        foregroundServiceGateway.stop()
        trackingEventEmitter.stopProviderMonitoring()
        trackingEventEmitter.emitEnabledChange(false)
        logManager.log("info", "stop")
    }

    fun onMotionChange(isMoving: Boolean) {
        trackingStats.onMotionChange(isMoving)
    }

    fun shutdown() {
        motionManager.stop()
        locationClient.stop()
        foregroundServiceGateway.stop()
        trackingEventEmitter.stopProviderMonitoring()
    }

    companion object {
        private const val TAG = "locus"
    }
}

internal fun shouldStartForegroundService(
    configured: Boolean,
    supportedBySdk: Boolean,
    origin: TrackingStartOrigin,
): Boolean = configured &&
    supportedBySdk &&
    origin != TrackingStartOrigin.FOREGROUND_SERVICE_RECOVERY
