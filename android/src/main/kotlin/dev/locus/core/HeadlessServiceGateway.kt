package dev.locus.core

/**
 * Core-facing boundary for starting Android headless-service work.
 *
 * Payload construction and fallback policy remain in core; the concrete
 * Android service classes stay behind the implementation in `service/`.
 */
interface HeadlessServiceGateway {
    fun dispatchEvent(
        dispatcherHandle: Long,
        callbackHandle: Long,
        eventJson: String,
    )

    fun refreshHeaders(
        dispatcherHandle: Long,
        callbackHandle: Long,
        timeoutMs: Long,
        callback: (Map<String, String>?) -> Unit,
    )

    fun validate(
        dispatcherHandle: Long,
        callbackHandle: Long,
        payloadJson: String,
        timeoutMs: Long,
        callback: (Boolean) -> Unit,
    )
}
