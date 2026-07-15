package dev.locus.core

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/** Background-safe state/stop endpoint used only by the recovery smoke APK. */
class RecoveryTestReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            RecoveryTestContract.ACTION_REPORT -> RecoveryTestCommands.reportState(context)
            RecoveryTestContract.ACTION_STOP -> RecoveryTestCommands.stopTracking(context)
        }
    }
}
