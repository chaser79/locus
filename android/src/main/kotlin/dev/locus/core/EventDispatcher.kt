package dev.locus.core

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.EventChannel

class EventDispatcher(
    private val headlessDispatcher: HeadlessDispatcher
) {
    private val mainHandler = Handler(Looper.getMainLooper())

    private val eventSinkRegistry = EngineBindingRegistry<EventChannel.EventSink>()

    fun setEventSink(owner: Any, sink: EventChannel.EventSink) =
        eventSinkRegistry.claim(owner, sink)

    fun clearEventSink(owner: Any) {
        eventSinkRegistry.release(owner)
    }

    fun sendEvent(
        event: Map<String, Any>,
        containsRawLocation: Boolean = false,
        privacyGuardEnabled: Boolean = false,
    ) {
        when (
            eventDeliveryRoute(
                hasEventSink = eventSinkRegistry.current() != null,
                containsRawLocation = containsRawLocation,
                privacyGuardEnabled = privacyGuardEnabled,
            )
        ) {
            EventDeliveryRoute.HEADLESS -> {
                headlessDispatcher.dispatch(event)
                return
            }
            EventDeliveryRoute.SUPPRESSED -> return
            EventDeliveryRoute.EVENT_SINK -> Unit
        }
        mainHandler.post {
            val activeSink = eventSinkRegistry.current()
            if (activeSink == null) {
                if (
                    eventDeliveryRoute(
                        hasEventSink = false,
                        containsRawLocation = containsRawLocation,
                        privacyGuardEnabled = privacyGuardEnabled,
                    ) == EventDeliveryRoute.HEADLESS
                ) {
                    headlessDispatcher.dispatch(event)
                }
            } else {
                activeSink.success(event)
            }
        }
    }
}

internal enum class EventDeliveryRoute {
    EVENT_SINK,
    HEADLESS,
    SUPPRESSED,
}

/**
 * A live UI engine receives raw locations because Dart owns zone-specific
 * exclusion and obfuscation. Headless callbacks have no restored zone graph,
 * so the durable native guard must fail closed until Dart releases it.
 */
internal fun eventDeliveryRoute(
    hasEventSink: Boolean,
    containsRawLocation: Boolean,
    privacyGuardEnabled: Boolean,
): EventDeliveryRoute = when {
    hasEventSink -> EventDeliveryRoute.EVENT_SINK
    containsRawLocation && privacyGuardEnabled -> EventDeliveryRoute.SUPPRESSED
    else -> EventDeliveryRoute.HEADLESS
}
