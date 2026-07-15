package dev.locus.location

import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.location.Location
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.core.content.ContextCompat
import com.google.android.gms.location.FusedLocationProviderClient
import com.google.android.gms.location.LocationCallback
import com.google.android.gms.location.LocationRequest
import com.google.android.gms.location.LocationResult
import com.google.android.gms.location.LocationServices
import com.google.android.gms.location.Priority
import com.google.android.gms.tasks.CancellationTokenSource
import dev.locus.core.ConfigManager

class LocationClient(
    private val context: Context,
    private val config: ConfigManager
) {
    private val fusedLocationClient: FusedLocationProviderClient =
        LocationServices.getFusedLocationProviderClient(context)

    private val mainHandler = Handler(Looper.getMainLooper())
    private val registrationState = LocationRegistrationState<LocationCallback>()
    private var registrationTimeout: Runnable? = null
    private var pendingStartCompletion: ((Boolean) -> Unit)? = null
    private var listener: LocationClientListener? = null
    private var currentPositionCts: CancellationTokenSource? = null

    // State
    private var currentPriority: Int = Priority.PRIORITY_HIGH_ACCURACY

    interface LocationClientListener {
        fun onLocation(location: Location)
        fun onLocationError(code: String, message: String)
    }

    fun interface LocationResultCallback {
        fun onSuccess(location: Location)
        fun onError(code: String, message: String) {}
    }

    fun setListener(listener: LocationClientListener?) {
        this.listener = listener
    }

    @SuppressLint("MissingPermission")
    fun start(onComplete: (Boolean) -> Unit) {
        if (!hasPermission()) {
            listener?.onLocationError("PERMISSION_DENIED", "Location permission missing")
            onComplete(false)
            return
        }

        stop()

        val request = buildLocationRequest(config.desiredAccuracy, config.stationaryRadius)
        register(request, isInitialStart = true, onComplete = onComplete)
    }

    fun stop() {
        currentPositionCts?.cancel()
        currentPositionCts = null
        cancelRegistrationTimeout()
        completePendingStart(false)
        registrationState.stop().forEach { callback ->
            fusedLocationClient.removeLocationUpdates(callback)
        }
        Log.i(TAG, "Location updates stopped")
    }

    @SuppressLint("MissingPermission")
    fun updateRequest(isMoving: Boolean) {
        if (registrationState.active == null || !hasPermission()) return

        val minDistance = if (isMoving) config.distanceFilter else config.stationaryRadius
        val newRequest = buildLocationRequest(config.desiredAccuracy, minDistance)
        register(newRequest, isInitialStart = false) { success ->
            if (success) {
                Log.i(TAG, "Location request updated. Moving: $isMoving, Distance: $minDistance")
            }
        }
    }

    @SuppressLint("MissingPermission")
    fun getCurrentPosition(callback: LocationResultCallback) {
        if (!hasPermission()) {
            callback.onError("PERMISSION_DENIED", "Location permission not granted")
            return
        }

        // Cancel any in-flight single-location request
        currentPositionCts?.cancel()
        val cts = CancellationTokenSource()
        currentPositionCts = cts
        fusedLocationClient.getCurrentLocation(currentPriority, cts.token)
            .addOnSuccessListener { location ->
                currentPositionCts = null
                if (location == null) {
                    callback.onError("LOCATION_ERROR", "No location available")
                } else {
                    callback.onSuccess(location)
                }
            }
            .addOnFailureListener { e ->
                currentPositionCts = null
                callback.onError("LOCATION_ERROR", e.message ?: "Unknown error")
            }
    }

    fun hasPermission(): Boolean {
        val fine = ContextCompat.checkSelfPermission(
            context,
            android.Manifest.permission.ACCESS_FINE_LOCATION
        ) == PackageManager.PERMISSION_GRANTED

        val coarse = ContextCompat.checkSelfPermission(
            context,
            android.Manifest.permission.ACCESS_COARSE_LOCATION
        ) == PackageManager.PERMISSION_GRANTED

        return fine || coarse
    }

    private fun buildLocationRequest(desiredAccuracy: String?, minDistance: Float): LocationRequest {
        val priority = when (desiredAccuracy) {
            "navigation" -> Priority.PRIORITY_HIGH_ACCURACY
            "medium" -> Priority.PRIORITY_BALANCED_POWER_ACCURACY
            "low", "veryLow" -> Priority.PRIORITY_LOW_POWER
            "lowest" -> Priority.PRIORITY_PASSIVE
            else -> Priority.PRIORITY_HIGH_ACCURACY
        }

        currentPriority = priority

        return LocationRequest.Builder(priority, config.locationUpdateInterval)
            .setMinUpdateIntervalMillis(config.fastestLocationUpdateInterval)
            .setMinUpdateDistanceMeters(minDistance)
            .build()
    }

    @SuppressLint("MissingPermission")
    private fun register(
        request: LocationRequest,
        isInitialStart: Boolean,
        onComplete: (Boolean) -> Unit,
    ) {
        val callback = object : LocationCallback() {
            override fun onLocationResult(locationResult: LocationResult) {
                if (registrationState.active !== this) return
                locationResult.lastLocation?.let { listener?.onLocation(it) }
            }
        }
        val operation = registrationState.begin(callback)
        operation.superseded?.let { fusedLocationClient.removeLocationUpdates(it) }

        if (isInitialStart) {
            pendingStartCompletion = onComplete
        }

        val timeout = Runnable {
            if (!registrationState.reject(operation.token, callback)) return@Runnable
            fusedLocationClient.removeLocationUpdates(callback)
            val message = "Location update registration timed out"
            Log.e(TAG, message)
            listener?.onLocationError(ERROR_REGISTRATION_FAILED, message)
            if (isInitialStart) completePendingStart(false) else onComplete(false)
        }
        registrationTimeout = timeout
        mainHandler.postDelayed(timeout, REGISTRATION_TIMEOUT_MS)

        try {
            fusedLocationClient.requestLocationUpdates(request, callback, Looper.getMainLooper())
                .addOnSuccessListener {
                    val committed = registrationState.commit(operation.token, callback)
                    if (!committed.accepted) {
                        fusedLocationClient.removeLocationUpdates(callback)
                        return@addOnSuccessListener
                    }
                    cancelRegistrationTimeout()
                    committed.previous?.let { fusedLocationClient.removeLocationUpdates(it) }
                    Log.i(TAG, "Location updates registered")
                    if (isInitialStart) completePendingStart(true) else onComplete(true)
                }
                .addOnFailureListener { error ->
                    if (!registrationState.reject(operation.token, callback)) return@addOnFailureListener
                    cancelRegistrationTimeout()
                    Log.e(TAG, "Failed to register location updates", error)
                    listener?.onLocationError(
                        ERROR_REGISTRATION_FAILED,
                        error.message ?: "Failed to register location updates",
                    )
                    if (isInitialStart) completePendingStart(false) else onComplete(false)
                }
        } catch (error: RuntimeException) {
            registrationState.reject(operation.token, callback)
            cancelRegistrationTimeout()
            Log.e(TAG, "Failed to request location updates", error)
            listener?.onLocationError(
                ERROR_REGISTRATION_FAILED,
                error.message ?: "Failed to request location updates",
            )
            if (isInitialStart) completePendingStart(false) else onComplete(false)
        }
    }

    private fun cancelRegistrationTimeout() {
        registrationTimeout?.let(mainHandler::removeCallbacks)
        registrationTimeout = null
    }

    private fun completePendingStart(success: Boolean) {
        val completion = pendingStartCompletion
        pendingStartCompletion = null
        completion?.invoke(success)
    }

    companion object {
        internal const val ERROR_REGISTRATION_FAILED = "LOCATION_REGISTRATION_FAILED"
        private const val REGISTRATION_TIMEOUT_MS = 15_000L
        private const val TAG = "locus.LocationClient"
    }
}

internal data class RegistrationOperation<T : Any>(
    val token: Long,
    val superseded: T?,
)

internal data class RegistrationCommit<T : Any>(
    val accepted: Boolean,
    val previous: T? = null,
)

/** Pure operation state used to reject late Google Play services callbacks. */
internal class LocationRegistrationState<T : Any> {
    private var token = 0L

    var active: T? = null
        private set

    private var pending: T? = null

    fun begin(candidate: T): RegistrationOperation<T> {
        token += 1
        val superseded = pending
        pending = candidate
        return RegistrationOperation(token, superseded)
    }

    fun commit(operationToken: Long, candidate: T): RegistrationCommit<T> {
        if (operationToken != token || pending !== candidate) {
            return RegistrationCommit(accepted = false)
        }
        pending = null
        val previous = active
        active = candidate
        return RegistrationCommit(accepted = true, previous = previous)
    }

    fun reject(operationToken: Long, candidate: T): Boolean {
        if (operationToken != token || pending !== candidate) return false
        pending = null
        return true
    }

    fun stop(): List<T> {
        token += 1
        val callbacks = buildList {
            active?.let(::add)
            pending?.let { candidate -> if (candidate !== active) add(candidate) }
        }
        active = null
        pending = null
        return callbacks
    }
}
