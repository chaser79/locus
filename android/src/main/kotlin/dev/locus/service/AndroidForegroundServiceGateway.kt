package dev.locus.service

import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log
import dev.locus.core.ConfigManager
import dev.locus.core.ForegroundServiceGateway

internal class AndroidForegroundServiceGateway(context: Context) : ForegroundServiceGateway {
    private val applicationContext = context.applicationContext

    override fun start(config: ConfigManager): Boolean {
        val intent = Intent(applicationContext, ForegroundService::class.java).apply {
            putExtra("title", config.notificationTitle)
            putExtra("text", config.notificationText)
            putExtra("icon", config.notificationIcon)
            putExtra("id", config.notificationId)
            putExtra("importance", config.notificationImportance)
            if (config.notificationActions.isNotEmpty()) {
                putExtra("actions", config.notificationActions.toTypedArray())
            }
        }

        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                applicationContext.startForegroundService(intent)
            } else {
                applicationContext.startService(intent)
            }
            true
        } catch (error: RuntimeException) {
            Log.e(TAG, "Failed to start foreground service", error)
            false
        }
    }

    override fun stop() {
        applicationContext.stopService(Intent(applicationContext, ForegroundService::class.java))
    }

    override fun canUpdateNotification(): Boolean = ForegroundService.canUpdateNotification()

    override fun updateNotification(title: String?, text: String?): Boolean =
        ForegroundService.updateNotification(applicationContext, title, text)

    private companion object {
        const val TAG = "ForegroundServiceGateway"
    }
}
