package dev.locus.core

import org.junit.Assert.assertEquals
import org.junit.Test

class TrackingRecoveryPolicyTest {

    @Test
    fun `all input combinations follow recovery precedence`() {
        val statuses = PersistedConfigStatus.entries

        statuses.forEach { status ->
            listOf(false, true).forEach { hasPermission ->
                assertEquals(
                    TrackingRecoveryAction.NONE,
                    decideTrackingRecovery(false, false, status, hasPermission),
                )
                assertEquals(
                    TrackingRecoveryAction.STOP_RUNTIME,
                    decideTrackingRecovery(false, true, status, hasPermission),
                )
            }

            assertEquals(
                TrackingRecoveryAction.CLEAR_DESIRED_STATE,
                decideTrackingRecovery(true, false, status, false),
            )
            assertEquals(
                TrackingRecoveryAction.CLEAR_DESIRED_STATE,
                decideTrackingRecovery(true, true, status, false),
            )
            assertEquals(
                TrackingRecoveryAction.KEEP_RUNNING,
                decideTrackingRecovery(true, true, status, true),
            )
        }

        assertEquals(
            TrackingRecoveryAction.CLEAR_DESIRED_STATE,
            decideTrackingRecovery(true, false, PersistedConfigStatus.ABSENT, true),
        )
        assertEquals(
            TrackingRecoveryAction.WAIT_FOR_CONFIG,
            decideTrackingRecovery(true, false, PersistedConfigStatus.CORRUPT, true),
        )
        assertEquals(
            TrackingRecoveryAction.START,
            decideTrackingRecovery(true, false, PersistedConfigStatus.VALID, true),
        )
    }

    @Test
    fun `recovery actions converge to stable states`() {
        assertEquals(
            TrackingRecoveryAction.STOP_RUNTIME,
            decideTrackingRecovery(false, true, PersistedConfigStatus.VALID, true),
        )
        assertEquals(
            TrackingRecoveryAction.NONE,
            decideTrackingRecovery(false, false, PersistedConfigStatus.VALID, true),
        )

        assertEquals(
            TrackingRecoveryAction.CLEAR_DESIRED_STATE,
            decideTrackingRecovery(true, false, PersistedConfigStatus.VALID, false),
        )
        assertEquals(
            TrackingRecoveryAction.NONE,
            decideTrackingRecovery(false, false, PersistedConfigStatus.VALID, false),
        )

        assertEquals(
            TrackingRecoveryAction.WAIT_FOR_CONFIG,
            decideTrackingRecovery(true, false, PersistedConfigStatus.CORRUPT, true),
        )
        assertEquals(
            TrackingRecoveryAction.START,
            decideTrackingRecovery(true, false, PersistedConfigStatus.VALID, true),
        )
        assertEquals(
            TrackingRecoveryAction.KEEP_RUNNING,
            decideTrackingRecovery(true, true, PersistedConfigStatus.VALID, true),
        )

        assertEquals(
            TrackingRecoveryAction.START,
            decideTrackingRecovery(true, false, PersistedConfigStatus.VALID, true),
        )
        assertEquals(
            TrackingRecoveryAction.NONE,
            decideTrackingRecovery(false, false, PersistedConfigStatus.VALID, true),
        )
    }

    @Test
    fun `inactive durable state does nothing`() {
        val action = decideTrackingRecovery(
            trackingDesired = false,
            runtimeEnabled = false,
            configStatus = PersistedConfigStatus.VALID,
            hasPermission = true,
        )

        assertEquals(TrackingRecoveryAction.NONE, action)
    }

    @Test
    fun `inactive durable state stops a stale enabled runtime`() {
        val action = decideTrackingRecovery(
            trackingDesired = false,
            runtimeEnabled = true,
            configStatus = PersistedConfigStatus.VALID,
            hasPermission = true,
        )

        assertEquals(TrackingRecoveryAction.STOP_RUNTIME, action)
    }

    @Test
    fun `enabled runtime remains idempotent`() {
        val action = decideTrackingRecovery(
            trackingDesired = true,
            runtimeEnabled = true,
            configStatus = PersistedConfigStatus.VALID,
            hasPermission = true,
        )

        assertEquals(TrackingRecoveryAction.KEEP_RUNNING, action)
    }

    @Test
    fun `missing config clears durable desired state`() {
        val action = decideTrackingRecovery(
            trackingDesired = true,
            runtimeEnabled = false,
            configStatus = PersistedConfigStatus.ABSENT,
            hasPermission = true,
        )

        assertEquals(TrackingRecoveryAction.CLEAR_DESIRED_STATE, action)
    }

    @Test
    fun `missing permission clears durable desired state`() {
        val action = decideTrackingRecovery(
            trackingDesired = true,
            runtimeEnabled = false,
            configStatus = PersistedConfigStatus.VALID,
            hasPermission = false,
        )

        assertEquals(TrackingRecoveryAction.CLEAR_DESIRED_STATE, action)
    }

    @Test
    fun `missing permission clears desired state even when runtime reports enabled`() {
        val action = decideTrackingRecovery(
            trackingDesired = true,
            runtimeEnabled = true,
            configStatus = PersistedConfigStatus.VALID,
            hasPermission = false,
        )

        assertEquals(TrackingRecoveryAction.CLEAR_DESIRED_STATE, action)
    }

    @Test
    fun `valid persisted state starts runtime`() {
        val action = decideTrackingRecovery(
            trackingDesired = true,
            runtimeEnabled = false,
            configStatus = PersistedConfigStatus.VALID,
            hasPermission = true,
        )

        assertEquals(TrackingRecoveryAction.START, action)
    }

    @Test
    fun `corrupt config preserves desired state while waiting for replacement`() {
        val action = decideTrackingRecovery(
            trackingDesired = true,
            runtimeEnabled = false,
            configStatus = PersistedConfigStatus.CORRUPT,
            hasPermission = true,
        )

        assertEquals(TrackingRecoveryAction.WAIT_FOR_CONFIG, action)
    }

    @Test
    fun `missing permission takes precedence over corrupt config`() {
        val action = decideTrackingRecovery(
            trackingDesired = true,
            runtimeEnabled = false,
            configStatus = PersistedConfigStatus.CORRUPT,
            hasPermission = false,
        )

        assertEquals(TrackingRecoveryAction.CLEAR_DESIRED_STATE, action)
    }

    @Test
    fun `enabled runtime with permission keeps running despite corrupt disk snapshot`() {
        val action = decideTrackingRecovery(
            trackingDesired = true,
            runtimeEnabled = true,
            configStatus = PersistedConfigStatus.CORRUPT,
            hasPermission = true,
        )

        assertEquals(TrackingRecoveryAction.KEEP_RUNNING, action)
    }

}
