package dev.locus.core

/**
 * Core-facing boundary for the Android foreground-service runtime.
 *
 * The implementation lives in `service/`; keeping this contract in core
 * prevents lifecycle policy from depending on Android's concrete service.
 */
interface ForegroundServiceGateway {
    fun start(config: ConfigManager): Boolean

    fun stop()

    fun canUpdateNotification(): Boolean

    fun updateNotification(title: String?, text: String?): Boolean
}
