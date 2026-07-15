package dev.locus.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class UserRequestedStopPolicyTest {
    private val packageName = "dev.locus.host"
    private val userRequestedReason = 10

    @Test
    fun `first observation establishes a migration baseline without clearing intent`() {
        val observation = observeProcessExit(
            latest = exit(100, "fully stop $packageName/0 by user request"),
            historyInitialized = false,
            handledTimestampMillis = 0,
            packageName = packageName,
            userRequestedReason = userRequestedReason,
        )

        assertTrue(observation.initializeHistory)
        assertEquals(100L, observation.timestampToPersist)
        assertFalse(observation.clearsTrackingIntent)
    }

    @Test
    fun `new Task Manager stop clears tracking intent`() {
        val observation = observeProcessExit(
            latest = exit(200, "fully stop $packageName/0 by user request"),
            historyInitialized = true,
            handledTimestampMillis = 100,
            packageName = packageName,
            userRequestedReason = userRequestedReason,
        )

        assertEquals(200L, observation.timestampToPersist)
        assertTrue(observation.clearsTrackingIntent)
    }

    @Test
    fun `force stop clears tracking intent after the user opens the app`() {
        val observation = observeProcessExit(
            latest = exit(200, "stop $packageName due to from pid 1234"),
            historyInitialized = true,
            handledTimestampMillis = 100,
            packageName = packageName,
            userRequestedReason = userRequestedReason,
        )

        assertTrue(observation.clearsTrackingIntent)
    }

    @Test
    fun `recents task removal remains non-terminal`() {
        val observation = observeProcessExit(
            latest = exit(200, "remove task"),
            historyInitialized = true,
            handledTimestampMillis = 100,
            packageName = packageName,
            userRequestedReason = userRequestedReason,
        )

        assertEquals(200L, observation.timestampToPersist)
        assertFalse(observation.clearsTrackingIntent)
    }

    @Test
    fun `package update and unknown user requested exits do not clear intent`() {
        val observation = observeProcessExit(
            latest = exit(200, "package update"),
            historyInitialized = true,
            handledTimestampMillis = 100,
            packageName = packageName,
            userRequestedReason = userRequestedReason,
        )

        assertFalse(observation.clearsTrackingIntent)
    }

    @Test
    fun `already handled exit is ignored`() {
        val observation = observeProcessExit(
            latest = exit(100, "fully stop $packageName/0 by user request"),
            historyInitialized = true,
            handledTimestampMillis = 100,
            packageName = packageName,
            userRequestedReason = userRequestedReason,
        )

        assertEquals(null, observation.timestampToPersist)
        assertFalse(observation.clearsTrackingIntent)
    }

    private fun exit(timestamp: Long, description: String) = HistoricalProcessExit(
        timestampMillis = timestamp,
        reason = userRequestedReason,
        description = description,
    )
}
