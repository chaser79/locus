package dev.locus.core

import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.content.Context
import android.content.SharedPreferences
import android.os.Build
import android.util.Log
import java.util.Locale

internal data class HistoricalProcessExit(
    val timestampMillis: Long,
    val reason: Int,
    val description: String?,
)

internal data class ProcessExitObservation(
    val timestampToPersist: Long?,
    val initializeHistory: Boolean,
    val clearsTrackingIntent: Boolean,
)

/**
 * Classifies the latest exit without conflating Android's recents removal with
 * Task Manager Stop. Both use REASON_USER_REQUESTED, but AOSP exposes distinct
 * descriptions through ApplicationExitInfo. Unknown OEM descriptions remain
 * non-terminal to preserve `stopOnTerminate: false` recents behavior.
 */
internal fun observeProcessExit(
    latest: HistoricalProcessExit?,
    historyInitialized: Boolean,
    handledTimestampMillis: Long,
    packageName: String,
    userRequestedReason: Int,
): ProcessExitObservation {
    if (!historyInitialized) {
        return ProcessExitObservation(
            timestampToPersist = latest?.timestampMillis,
            initializeHistory = true,
            clearsTrackingIntent = false,
        )
    }
    if (latest == null || latest.timestampMillis <= handledTimestampMillis) {
        return ProcessExitObservation(null, initializeHistory = false, clearsTrackingIntent = false)
    }

    val description = latest.description.orEmpty().lowercase(Locale.ROOT)
    val normalizedPackage = packageName.lowercase(Locale.ROOT)
    val isExplicitStop = latest.reason == userRequestedReason && (
        description.startsWith("fully stop $normalizedPackage/") ||
            description.startsWith("stop $normalizedPackage due to")
        )
    return ProcessExitObservation(
        timestampToPersist = latest.timestampMillis,
        initializeHistory = false,
        clearsTrackingIntent = isExplicitStop,
    )
}

/**
 * Consumes process-exit history exactly once. The exit marker and tracking
 * intent are committed atomically so a storage failure cannot acknowledge a
 * user stop while leaving a recoverable `true` desired state behind.
 */
internal class UserRequestedStopHistory(
    private val context: Context,
    private val preferences: SharedPreferences,
) {
    fun consumeExplicitStop(
        trackingActiveKey: String,
        explicitStopActiveKey: String,
    ): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return false

        val latest = try {
            val activityManager = context.getSystemService(ActivityManager::class.java)
                ?: return false
            activityManager.getHistoricalProcessExitReasons(context.packageName, 0, MAX_EXIT_RECORDS)
                .asSequence()
                .filter { it.processName == context.applicationInfo.processName }
                .maxByOrNull { it.timestamp }
                ?.let {
                    HistoricalProcessExit(
                        timestampMillis = it.timestamp,
                        reason = it.reason,
                        description = it.description,
                    )
                }
        } catch (error: RuntimeException) {
            Log.w(TAG, "Unable to inspect process exit history", error)
            return false
        }

        val observation = observeProcessExit(
            latest = latest,
            historyInitialized = preferences.getBoolean(KEY_HISTORY_INITIALIZED, false),
            handledTimestampMillis = preferences.getLong(KEY_HANDLED_EXIT_TIMESTAMP, 0L),
            packageName = context.packageName,
            userRequestedReason = ApplicationExitInfo.REASON_USER_REQUESTED,
        )
        if (!observation.initializeHistory && observation.timestampToPersist == null) {
            return false
        }

        val committed = preferences.edit().apply {
            if (observation.initializeHistory) putBoolean(KEY_HISTORY_INITIALIZED, true)
            observation.timestampToPersist?.let { putLong(KEY_HANDLED_EXIT_TIMESTAMP, it) }
            if (observation.clearsTrackingIntent) {
                putBoolean(trackingActiveKey, false)
                putBoolean(explicitStopActiveKey, true)
            }
        }.commit()
        if (!committed) {
            Log.e(TAG, "Unable to persist process-exit reconciliation")
        } else if (observation.clearsTrackingIntent) {
            Log.i(TAG, "Cleared tracking intent after an explicit Android app stop")
        }
        return observation.clearsTrackingIntent
    }

    private companion object {
        const val TAG = "locus.ProcessExit"
        const val MAX_EXIT_RECORDS = 10
        const val KEY_HISTORY_INITIALIZED = "bg_exit_history_initialized_v1"
        const val KEY_HANDLED_EXIT_TIMESTAMP = "bg_handled_exit_timestamp_v1"
    }
}
