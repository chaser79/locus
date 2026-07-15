package dev.locus.core

import android.content.SharedPreferences
import org.json.JSONObject

class HeadlessDispatcher(
    private val config: ConfigManager,
    private val prefs: SharedPreferences?,
    private val serviceGateway: HeadlessServiceGateway,
) {
    fun dispatch(event: Map<String, Any>) {
        if (!config.enableHeadless || prefs == null) {
            return
        }
        
        val dispatcher = prefs.getLong(KEY_HEADLESS_DISPATCHER, 0L)
        val callback = prefs.getLong(KEY_HEADLESS_CALLBACK, 0L)
        
        if (dispatcher == 0L || callback == 0L) {
            return
        }
        
        runCatching {
            val payload = JSONObject(event)
            serviceGateway.dispatchEvent(dispatcher, callback, payload.toString())
        }
    }

    companion object {
        private const val KEY_HEADLESS_DISPATCHER = "bg_headless_dispatcher"
        private const val KEY_HEADLESS_CALLBACK = "bg_headless_callback"
    }
}
