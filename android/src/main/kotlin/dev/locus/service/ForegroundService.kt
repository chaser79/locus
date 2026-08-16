package dev.locus.service

import android.annotation.TargetApi
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Bundle
import android.os.IBinder
import android.util.Log
import dev.locus.core.ConfigManager
import dev.locus.core.LocusContainer
import dev.locus.core.TrackingRecoveryAction
import dev.locus.core.TrackingRecoveryOrigin
import dev.locus.receiver.NotificationActionReceiver

class ForegroundService : Service() {

    private var recoveryGeneration = 0L

    companion object {
        private const val TAG = "ForegroundService"
        private const val DEFAULT_NOTIFICATION_ID = 197812504
        // Android's built-in star icon as fallback
        private const val FALLBACK_ICON = 17301514

        // Saved state for dynamic notification updates
        private var lastExtras: Bundle? = null
        private var lastNotificationId: Int = DEFAULT_NOTIFICATION_ID

        /**
         * Updates the foreground notification content without restarting the service.
         * Only updates title and/or text; other notification properties (icon, actions)
         * are preserved from the original configuration.
         */
        @TargetApi(26)
        fun updateNotification(context: Context, title: String?, text: String?): Boolean {
            val extras = lastExtras ?: return false
            val updated = Bundle(extras).apply {
                if (title != null) putString("title", title)
                if (text != null) putString("text", text)
            }
            return try {
                val notification = buildNotification(context, updated) ?: return false
                val notificationManager = context.getSystemService(NotificationManager::class.java)
                    ?: return false
                notificationManager.notify(lastNotificationId, notification)
                lastExtras = Bundle(updated)
                true
            } catch (e: Exception) {
                Log.e(TAG, "Failed to update foreground notification", e)
                false
            }
        }

        fun canUpdateNotification(): Boolean = lastExtras != null

        fun clearNotificationState() {
            lastExtras = null
            lastNotificationId = DEFAULT_NOTIFICATION_ID
        }

        /**
         * Builds a full notification from the given extras and context.
         */
        @TargetApi(26)
        private fun buildNotification(context: Context, extras: Bundle): Notification? {
            val importanceValue = extras.getInt("importance", 1)
            val channelId = ensureConfiguredChannel(context, importanceValue)

            // Resolve notification icon
            val iconName = extras.getString("icon")
            var icon = 0
            if (iconName != null) {
                icon = context.resources.getIdentifier(
                    iconName, "drawable", context.packageName
                )
            }
            if (icon == 0) {
                icon = context.resources.getIdentifier(
                    "ic_launcher", "mipmap", context.packageName
                )
            }

            val builder = Notification.Builder(context, channelId)
                .setContentTitle(extras.getString("title"))
                .setContentText(extras.getString("text"))
                .setOngoing(true)
                .setSmallIcon(if (icon != 0) icon else FALLBACK_ICON)

            // Add notification actions if present
            extras.getStringArray("actions")?.filterNotNull()?.forEach { actionId ->
                val actionIntent = Intent(
                    context, NotificationActionReceiver::class.java
                ).apply {
                    action = actionId
                }
                val pendingIntent = PendingIntent.getBroadcast(
                    context,
                    actionId.hashCode(),
                    actionIntent,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                )
                builder.addAction(0, actionId, pendingIntent)
            }

            return builder.build()
        }

        @TargetApi(26)
        private fun ensureConfiguredChannel(context: Context, importanceValue: Int): String {
            val channelId = notificationChannelId(importanceValue)
            val channel = NotificationChannel(
                channelId,
                "Background Services",
                notificationChannelImportance(importanceValue),
            ).apply {
                description = "Enables background location processing."
            }
            context.getSystemService(NotificationManager::class.java)
                ?.createNotificationChannel(channel)
            return channelId
        }
    }

    @TargetApi(26)
    override fun onCreate() {
        super.onCreate()
        // The bootstrap channel is deliberately separate from configured
        // channels. Android channel importance is immutable after creation, so
        // pre-creating the legacy configured channel at LOW would permanently
        // downgrade later DEFAULT/HIGH requests.
        val channel = NotificationChannel(
            BOOTSTRAP_CHANNEL_ID,
            "Background Service Startup",
            NotificationManager.IMPORTANCE_LOW
        ).apply {
            description = "Shown briefly while background location tracking starts."
        }
        getSystemService(NotificationManager::class.java)?.createNotificationChannel(channel)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val extras = intent?.extras
        val notificationId = extras?.getInt("id", DEFAULT_NOTIFICATION_ID) ?: DEFAULT_NOTIFICATION_ID

        // Immediately promote to foreground with a minimal notification.
        // This MUST happen as fast as possible to avoid the 5-second
        // ForegroundServiceDidNotStartInTimeException on Android 14+.
        if (!promoteToForeground(notificationId, buildMinimalNotification())) {
            stopTrackingForTerminalFailure()
            stopForegroundAndSelf(startId)
            return START_NOT_STICKY
        }

        // START_STICKY process recovery may arrive with a null intent. Reconcile
        // runtime state for every command; intent extras are presentation data,
        // never the recovery source of truth.
        recoveryGeneration += 1
        recoverFromPersistedState(startId, recoveryGeneration)
        return START_STICKY
    }

    private fun recoverFromPersistedState(startId: Int, generation: Long) {
        var container: LocusContainer? = null
        try {
            val acquiredContainer = LocusContainer.acquire(
                applicationContext,
                AndroidForegroundServiceGateway(applicationContext),
                AndroidHeadlessServiceGateway(applicationContext),
            )
            container = acquiredContainer
            acquiredContainer.reconcilePersistedTrackingState(
                TrackingRecoveryOrigin.FOREGROUND_SERVICE,
            ) recovery@{ recovery ->
                if (generation != recoveryGeneration) return@recovery

                when (recovery) {
                    TrackingRecoveryAction.KEEP_RUNNING -> {
                        val restoredExtras = notificationExtras(acquiredContainer.configManager)
                        val restoredNotificationId = acquiredContainer.configManager.notificationId
                        val notificationShown = showConfiguredNotification(
                            restoredExtras,
                            restoredNotificationId,
                        )
                        if (!notificationShown) {
                            Log.w(
                                TAG,
                                "Recovered tracking is keeping the minimal foreground notification",
                            )
                        }
                    }
                    TrackingRecoveryAction.WAIT_FOR_CONFIG -> {
                        Log.e(TAG, "Sticky restart blocked by corrupt persisted configuration")
                        stopForegroundAndSelf(startId)
                    }
                    else -> {
                        Log.i(
                            TAG,
                            "Sticky restart stopped because tracking is not recoverable: $recovery",
                        )
                        stopForegroundAndSelf(startId)
                    }
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to recover tracking after process recreation", e)
            val tracker = container?.locationTracker
            tracker?.stopTracking()
            stopForegroundAndSelf(startId)
        }
    }

    private fun notificationExtras(config: ConfigManager): Bundle = Bundle().apply {
        putString("title", config.notificationTitle)
        putString("text", config.notificationText)
        putString("icon", config.notificationIcon)
        putInt("id", config.notificationId)
        putInt("importance", config.notificationImportance)
        if (config.notificationActions.isNotEmpty()) {
            putStringArray("actions", config.notificationActions.toTypedArray())
        }
    }

    private fun showConfiguredNotification(extras: Bundle, notificationId: Int): Boolean {
        return try {
            val fullNotification = buildNotification(applicationContext, extras)
                ?: return false
            if (promoteToForeground(notificationId, fullNotification)) {
                lastExtras = Bundle(extras)
                lastNotificationId = notificationId
                true
            } else {
                showFallbackNotification(extras, notificationId)
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to build configured notification; using safe fallback", e)
            showFallbackNotification(extras, notificationId)
        }
    }

    private fun showFallbackNotification(extras: Bundle, notificationId: Int): Boolean {
        return try {
            if (!promoteToForeground(notificationId, buildFallbackNotification(extras))) return false
            lastExtras = Bundle(extras)
            lastNotificationId = notificationId
            true
        } catch (error: RuntimeException) {
            Log.e(TAG, "Failed to show fallback foreground notification", error)
            false
        }
    }

    @TargetApi(26)
    private fun buildMinimalNotification(): Notification {
        return Notification.Builder(applicationContext, BOOTSTRAP_CHANNEL_ID)
            .setContentTitle("Starting...")
            .setOngoing(true)
            .setSmallIcon(FALLBACK_ICON)
            .build()
    }

    @TargetApi(26)
    private fun buildFallbackNotification(extras: Bundle): Notification {
        val channelId = ensureConfiguredChannel(
            applicationContext,
            extras.getInt("importance", 1),
        )
        return Notification.Builder(applicationContext, channelId)
            .setContentTitle("Locus")
            .setContentText("Tracking location in background.")
            .setOngoing(true)
            .setSmallIcon(FALLBACK_ICON)
            .build()
    }

    private fun promoteToForeground(id: Int, notification: Notification): Boolean {
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(id, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION)
            } else {
                startForeground(id, notification)
            }
            true
        } catch (error: RuntimeException) {
            // The platform may reject promotion because permission was revoked,
            // background FGS start is disallowed, or the declared service type
            // is invalid. Every rejection is terminal for this start command.
            Log.e(TAG, "Failed to promote location service to foreground", error)
            false
        }
    }

    private fun stopForegroundAndSelf(startId: Int) {
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf(startId)
    }

    private fun stopTrackingForTerminalFailure() {
        val tracker = LocusContainer.peek()?.locationTracker
        if (tracker == null) {
            ConfigManager(applicationContext).setTrackingActive(false)
            return
        }
        tracker.stopTracking()
    }

    override fun onDestroy() {
        recoveryGeneration += 1
        clearNotificationState()
        super.onDestroy()
    }

    /**
     * Called when the user swipes the task away from the recents screen. The default
     * behavior on many OEMs (notably Samsung One UI and Xiaomi MIUI) is to stop the
     * associated service. Keep tracking only when the persisted configuration says
     * task removal is non-terminal; otherwise clear durable intent before stopping.
     */
    override fun onTaskRemoved(rootIntent: Intent?) {
        val container = LocusContainer.peek()
        if (container?.configManager?.stopOnTerminate == true) {
            Log.i(TAG, "onTaskRemoved: stopOnTerminate=true - stopping tracking")
            if (!container.locationTracker.stopTracking()) {
                Log.e(TAG, "onTaskRemoved: tracking stopped but durable intent could not be cleared")
            }
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
            return
        }
        Log.i(TAG, "onTaskRemoved: task swiped away - keeping foreground service alive")
        super.onTaskRemoved(rootIntent)
    }

    override fun onBind(intent: Intent?): IBinder? = null
}

internal const val BOOTSTRAP_CHANNEL_ID = "foreground.service.bootstrap"
internal const val LEGACY_LOW_CHANNEL_ID = "foreground.service.channel"
internal const val DEFAULT_CHANNEL_ID = "foreground.service.channel.default"
internal const val HIGH_CHANNEL_ID = "foreground.service.channel.high"

internal fun notificationChannelId(importanceValue: Int): String = when (importanceValue) {
    2 -> DEFAULT_CHANNEL_ID
    3 -> HIGH_CHANNEL_ID
    else -> LEGACY_LOW_CHANNEL_ID
}

internal fun notificationChannelImportance(importanceValue: Int): Int = when (importanceValue) {
    2 -> NotificationManager.IMPORTANCE_DEFAULT
    3 -> NotificationManager.IMPORTANCE_HIGH
    else -> NotificationManager.IMPORTANCE_LOW
}
