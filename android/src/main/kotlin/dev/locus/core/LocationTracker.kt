package dev.locus.core

import android.annotation.SuppressLint
import android.location.Location
import dev.locus.activity.MotionManager
import dev.locus.location.LocationClient

class LocationTracker(
    private val config: ConfigManager,
    private val locationClient: LocationClient,
    private val motionManager: MotionManager,
    private val stateManager: StateManager,
    private val eventProcessor: LocationEventProcessor,
    private val payloadBuilder: LocationPayloadBuilder,
    private val locationUpdateProcessor: LocationUpdateProcessor,
    private val trackingLifecycleController: TrackingLifecycleController,
    private val trackingConfigApplier: TrackingConfigApplier
) {
    private val heartbeatScheduler = HeartbeatScheduler()
    private var lastLocation: Location? = null
    private var runtimeState = TrackingRuntimeState.STOPPED
    private val pendingStartCallbacks = mutableListOf<(Boolean) -> Unit>()

    init {
        locationClient.setListener(object : LocationClient.LocationClientListener {
            override fun onLocation(location: Location) {
                lastLocation = location
                locationUpdateProcessor.handleLocation(location)
            }

            override fun onLocationError(code: String, message: String) {
                locationUpdateProcessor.handleError(message)
            }
        })

        motionManager.setListener(object : MotionManager.MotionListener {
            override fun onMotionChange(isMoving: Boolean) {
                locationClient.updateRequest(isMoving)
                trackingLifecycleController.onMotionChange(isMoving)
                lastLocation?.let { emitLocationEvent(it, "motionchange") }
            }

            override fun onActivityChange(type: String, confidence: Int) {
                lastLocation?.let { emitLocationEvent(it, "activitychange") }
            }
        })
    }

    fun isEnabled(): Boolean = runtimeState == TrackingRuntimeState.RUNNING

    fun isMoving(): Boolean = motionManager.isMoving

    fun getLastLocation(): Location? = lastLocation

    fun buildState(): Map<String, Any> = buildMap {
        put("enabled", isEnabled())
        put("isMoving", motionManager.isMoving)
        put("odometer", stateManager.odometerValue)
        lastLocation?.let { location ->
            put("location", payloadBuilder.build(location, "location"))
        }
    }

    fun buildLocationPayload(location: Location, eventName: String): Map<String, Any> {
        return payloadBuilder.build(location, eventName)
    }

    fun applyConfig(configMap: Map<String, Any>?): Boolean {
        return trackingConfigApplier.apply(configMap, isEnabled())
    }

    @SuppressLint("MissingPermission")
    internal fun startTracking(
        origin: TrackingStartOrigin = TrackingStartOrigin.STANDARD,
        onComplete: (Boolean) -> Unit = {},
    ) {
        when (runtimeState) {
            TrackingRuntimeState.RUNNING -> {
                onComplete(true)
                return
            }
            TrackingRuntimeState.STARTING -> {
                pendingStartCallbacks += onComplete
                return
            }
            TrackingRuntimeState.STOPPED -> Unit
        }

        // Persist intent before starting the foreground service. Its start
        // command validates this bit so a stale queued command cannot revive
        // tracking after stop, and a current command cannot race this write.
        if (!config.setTrackingActive(true)) {
            onComplete(false)
            return
        }

        runtimeState = TrackingRuntimeState.STARTING
        pendingStartCallbacks += onComplete
        trackingLifecycleController.start(origin) lifecycle@{ started ->
            if (runtimeState != TrackingRuntimeState.STARTING) return@lifecycle

            runtimeState = if (started) {
                startHeartbeat()
                TrackingRuntimeState.RUNNING
            } else {
                if (!config.setTrackingActive(false)) {
                    locationUpdateProcessor.handleError(
                        "Tracking startup failed and desired state could not be cleared",
                    )
                }
                TrackingRuntimeState.STOPPED
            }

            completeStarts(started)
        }
    }

    internal fun stopTracking(): Boolean {
        // Runtime teardown is unconditional. A storage failure must never keep
        // sensors or the foreground service alive merely because durable state
        // could not be cleared.
        val persisted = config.setTrackingActive(false)
        forceStopRuntime()
        return persisted
    }

    internal fun forceStopRuntime() {
        runtimeState = TrackingRuntimeState.STOPPED
        trackingLifecycleController.stop()
        stopHeartbeat()
        completeStarts(false)
    }

    fun changePace(moving: Boolean) {
        motionManager.setPace(moving)
    }

    fun emitScheduleEvent() {
        if (!config.scheduleEnabled) return
        lastLocation?.let { emitLocationEvent(it, "configManager.schedule") }
    }

    fun syncNow() {
        val payload = lastLocation?.let { payloadBuilder.build(it, "location") }
        eventProcessor.syncNow(payload)
    }

    fun startHeartbeat() {
        heartbeatScheduler.start(config.heartbeatIntervalSeconds) {
            if (isEnabled()) {
                lastLocation?.let { emitLocationEvent(it, "heartbeat") }
            }
        }
    }

    fun stopHeartbeat() {
        heartbeatScheduler.stop()
    }

    /**
     * Restarts the heartbeat with the current configuration.
     * Call when heartbeat interval changes dynamically.
     */
    fun restartHeartbeat() {
        heartbeatScheduler.restart(config.heartbeatIntervalSeconds) {
            if (isEnabled()) {
                lastLocation?.let { emitLocationEvent(it, "heartbeat") }
            }
        }
    }

    private fun emitLocationEvent(location: Location, eventName: String) {
        val payload = payloadBuilder.build(location, eventName)
        eventProcessor.dispatch(eventName, payload)
    }

    private fun completeStarts(success: Boolean) {
        val callbacks = pendingStartCallbacks.toList()
        pendingStartCallbacks.clear()
        callbacks.forEach { it(success) }
    }

    /**
     * Full teardown: stops tracking and shuts the lifecycle controller down. Call
     * this when the owning container is itself shutting down. Not called during
     * normal FlutterEngine detach — the container outlives engine detach and the
     * tracker keeps running so the foreground service survives UI teardown.
     */
    fun releaseAll() {
        stopTracking()
        trackingLifecycleController.shutdown()
    }
}

internal enum class TrackingRuntimeState {
    STOPPED,
    STARTING,
    RUNNING,
}
