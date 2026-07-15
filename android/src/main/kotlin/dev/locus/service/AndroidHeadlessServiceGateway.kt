package dev.locus.service

import android.content.Context
import android.content.Intent
import dev.locus.core.HeadlessServiceGateway

internal class AndroidHeadlessServiceGateway(context: Context) : HeadlessServiceGateway {
    private val applicationContext = context.applicationContext

    override fun dispatchEvent(
        dispatcherHandle: Long,
        callbackHandle: Long,
        eventJson: String,
    ) {
        val intent = Intent(applicationContext, HeadlessService::class.java).apply {
            putExtra("dispatcher", dispatcherHandle)
            putExtra("callback", callbackHandle)
            putExtra("event", eventJson)
        }
        HeadlessService.enqueueWork(applicationContext, intent)
    }

    override fun refreshHeaders(
        dispatcherHandle: Long,
        callbackHandle: Long,
        timeoutMs: Long,
        callback: (Map<String, String>?) -> Unit,
    ) {
        val intent = Intent(applicationContext, HeadlessHeadersService::class.java).apply {
            putExtra("dispatcher", dispatcherHandle)
            putExtra("callback", callbackHandle)
            putExtra("timeoutMs", timeoutMs)
        }
        HeadlessHeadersService.enqueueWork(applicationContext, intent, callback)
    }

    override fun validate(
        dispatcherHandle: Long,
        callbackHandle: Long,
        payloadJson: String,
        timeoutMs: Long,
        callback: (Boolean) -> Unit,
    ) {
        val intent = Intent(applicationContext, HeadlessValidationService::class.java).apply {
            putExtra("dispatcher", dispatcherHandle)
            putExtra("callback", callbackHandle)
            putExtra("payload", payloadJson)
            putExtra("timeoutMs", timeoutMs)
        }
        HeadlessValidationService.enqueueWork(applicationContext, intent, callback)
    }
}
