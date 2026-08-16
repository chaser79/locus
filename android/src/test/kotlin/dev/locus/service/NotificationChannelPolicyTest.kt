package dev.locus.service

import android.app.NotificationManager
import org.junit.Assert.assertEquals
import org.junit.Test

class NotificationChannelPolicyTest {
    @Test
    fun `low importance retains legacy channel for existing user settings`() {
        assertEquals(LEGACY_LOW_CHANNEL_ID, notificationChannelId(1))
        assertEquals(NotificationManager.IMPORTANCE_LOW, notificationChannelImportance(1))
    }

    @Test
    fun `default and high importance use channels created at requested level`() {
        assertEquals(DEFAULT_CHANNEL_ID, notificationChannelId(2))
        assertEquals(NotificationManager.IMPORTANCE_DEFAULT, notificationChannelImportance(2))
        assertEquals(HIGH_CHANNEL_ID, notificationChannelId(3))
        assertEquals(NotificationManager.IMPORTANCE_HIGH, notificationChannelImportance(3))
    }

    @Test
    fun `unknown importance remains backward compatible with low behavior`() {
        assertEquals(LEGACY_LOW_CHANNEL_ID, notificationChannelId(Int.MAX_VALUE))
        assertEquals(
            NotificationManager.IMPORTANCE_LOW,
            notificationChannelImportance(Int.MAX_VALUE),
        )
    }
}
