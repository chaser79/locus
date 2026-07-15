package dev.locus.core

import android.content.SharedPreferences
import android.os.Handler
import android.os.Looper
import android.util.Log

class HeadlessHeadersDispatcher(
    private val config: ConfigManager,
    private val prefs: SharedPreferences?,
    private val serviceGateway: HeadlessServiceGateway,
) {
    private val mainHandler = Handler(Looper.getMainLooper())

    fun refreshHeaders(
        callback: (Map<String, String>?) -> Unit,
        timeoutMs: Long = 10_000L,
    ) {
        if (!config.enableHeadless || prefs == null) {
            callback(null)
            return
        }

        val dispatcher = prefs.getLong(KEY_HEADERS_DISPATCHER, 0L)
        val headersCallback = prefs.getLong(KEY_HEADERS_CALLBACK, 0L)
        if (dispatcher == 0L || headersCallback == 0L) {
            callback(null)
            return
        }

        runCatching {
            serviceGateway.refreshHeaders(dispatcher, headersCallback, timeoutMs) { headers ->
                mainHandler.post { callback(headers) }
            }
        }.onFailure { error ->
            Log.e(TAG, "Failed to dispatch headless headers refresh: ${error.message}")
            callback(null)
        }
    }

    fun isAvailable(): Boolean {
        if (!config.enableHeadless || prefs == null) return false
        val dispatcher = prefs.getLong(KEY_HEADERS_DISPATCHER, 0L)
        val callback = prefs.getLong(KEY_HEADERS_CALLBACK, 0L)
        return dispatcher != 0L && callback != 0L
    }

    companion object {
        private const val TAG = "locus.HeadlessHeaders"
        const val KEY_HEADERS_DISPATCHER = "bg_headless_headers_dispatcher"
        const val KEY_HEADERS_CALLBACK = "bg_headless_headers_callback"
    }
}
