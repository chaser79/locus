package dev.locus.core

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class TrackingLifecyclePolicyTest {

    @Test
    fun `service recovery never starts a second foreground service`() {
        assertFalse(
            shouldStartForegroundService(
                configured = true,
                supportedBySdk = true,
                origin = TrackingStartOrigin.FOREGROUND_SERVICE_RECOVERY,
            ),
        )
        assertTrue(
            shouldStartForegroundService(
                configured = true,
                supportedBySdk = true,
                origin = TrackingStartOrigin.STANDARD,
            ),
        )
        assertFalse(
            shouldStartForegroundService(
                configured = false,
                supportedBySdk = true,
                origin = TrackingStartOrigin.STANDARD,
            ),
        )
        assertFalse(
            shouldStartForegroundService(
                configured = true,
                supportedBySdk = false,
                origin = TrackingStartOrigin.STANDARD,
            ),
        )
    }
}
