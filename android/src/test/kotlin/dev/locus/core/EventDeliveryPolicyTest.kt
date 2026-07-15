package dev.locus.core

import org.junit.Assert.assertEquals
import org.junit.Test

class EventDeliveryPolicyTest {
    @Test
    fun `guarded raw location is suppressed without a live engine`() {
        assertEquals(
            EventDeliveryRoute.SUPPRESSED,
            eventDeliveryRoute(
                hasEventSink = false,
                containsRawLocation = true,
                privacyGuardEnabled = true,
            ),
        )
    }

    @Test
    fun `guarded raw location still reaches the UI privacy filter`() {
        assertEquals(
            EventDeliveryRoute.EVENT_SINK,
            eventDeliveryRoute(
                hasEventSink = true,
                containsRawLocation = true,
                privacyGuardEnabled = true,
            ),
        )
    }

    @Test
    fun `unguarded raw location keeps headless delivery`() {
        assertEquals(
            EventDeliveryRoute.HEADLESS,
            eventDeliveryRoute(
                hasEventSink = false,
                containsRawLocation = true,
                privacyGuardEnabled = false,
            ),
        )
    }

    @Test
    fun `non-location event keeps headless delivery while guarded`() {
        assertEquals(
            EventDeliveryRoute.HEADLESS,
            eventDeliveryRoute(
                hasEventSink = false,
                containsRawLocation = false,
                privacyGuardEnabled = true,
            ),
        )
    }
}
