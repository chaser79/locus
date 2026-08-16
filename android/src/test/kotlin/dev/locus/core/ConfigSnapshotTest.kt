package dev.locus.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class ConfigSnapshotTest {

    @Test
    fun `encrypted envelope round trips opaque bytes without exposing plaintext`() {
        val iv = ByteArray(SecureConfigSnapshotStore.GCM_IV_BYTES) { it.toByte() }
        val ciphertext = "Authorization: Bearer secret".toByteArray()

        val serialized = ConfigSnapshotEnvelope.encode(
            EncryptedConfigSnapshot(iv, ciphertext),
        )
        val decoded = ConfigSnapshotEnvelope.decode(serialized)
            ?: error("encrypted envelope must decode")

        assertTrue(serialized.startsWith(ConfigSnapshotEnvelope.PREFIX))
        assertEquals(false, serialized.contains("Authorization"))
        assertEquals(false, serialized.contains("secret"))
        assertTrue(iv.contentEquals(decoded.iv))
        assertTrue(ciphertext.contentEquals(decoded.ciphertext))
    }

    @Test
    fun `legacy plaintext remains readable with all configuration fields`() {
        val legacy = """{"distanceFilter":25,"headers":{"Authorization":"Bearer old"}}"""
        val legacyValues = mapOf<String, Any>(
            "distanceFilter" to 25,
            "headers" to mapOf("Authorization" to "Bearer old"),
            "params" to mapOf("api_key" to "legacy-key"),
            "extras" to mapOf("task_id" to "42"),
        )

        assertNull(ConfigSnapshotEnvelope.decode(legacy))
        val decoded = decodePersistedConfig(legacy) { serialized ->
            assertEquals(legacy, serialized)
            legacyValues
        }
        assertEquals(PersistedConfigStatus.VALID, decoded.status)
        assertEquals(legacyValues, decoded.values)
    }

    @Test
    fun `envelope decoder rejects malformed encrypted values without plaintext fallback`() {
        assertThrows(IllegalArgumentException::class.java) {
            ConfigSnapshotEnvelope.decode("${ConfigSnapshotEnvelope.PREFIX}not-an-envelope")
        }
        assertThrows(IllegalArgumentException::class.java) {
            ConfigSnapshotEnvelope.decode("${ConfigSnapshotEnvelope.PREFIX}AA:AA")
        }
    }

    @Test
    fun `persisted config decoder distinguishes absent corrupt and valid snapshots`() {
        var decoderCalled = false
        val absent = decodePersistedConfig(null) {
            decoderCalled = true
            emptyMap()
        }
        val corrupt = decodePersistedConfig("not-json") {
            throw IllegalArgumentException("malformed")
        }
        val nested = mapOf<String, Any>(
            "notification" to mapOf("actions" to listOf("PAUSE", "STOP")),
        )
        val valid = decodePersistedConfig("serialized") { nested }

        assertEquals(PersistedConfigStatus.ABSENT, absent.status)
        assertEquals(emptyMap<String, Any>(), absent.values)
        assertNull(absent.error)
        assertEquals(false, decoderCalled)

        assertEquals(PersistedConfigStatus.CORRUPT, corrupt.status)
        assertEquals(emptyMap<String, Any>(), corrupt.values)
        assertNotNull(corrupt.error)

        assertEquals(PersistedConfigStatus.VALID, valid.status)
        assertSame(nested, valid.values)
        assertNull(valid.error)
    }

    @Test
    fun `notification patch preserves existing and unknown fields`() {
        val original = mapOf<String, Any>(
            "distanceFilter" to 25,
            "notification" to mapOf(
                "title" to "Old",
                "text" to "Old text",
                "smallIcon" to "tracking",
                "actions" to listOf("PAUSE"),
                "importance" to 2,
                "futureField" to "preserved",
            ),
        )

        val patched = patchNotificationContent(original, title = "Trip", text = null)
        val notification = patched["notification"] as? Map<*, *>
            ?: error("notification must remain a map")

        assertEquals(25, patched["distanceFilter"])
        assertEquals("Trip", notification["title"])
        assertEquals("Old text", notification["text"])
        assertEquals("tracking", notification["smallIcon"])
        assertEquals(listOf("PAUSE"), notification["actions"])
        assertEquals(2, notification["importance"])
        assertEquals("preserved", notification["futureField"])
    }

    @Test
    fun `notification patch accepts empty text and null null is a no-op`() {
        val original = mapOf<String, Any>("notification" to mapOf("text" to "Old"))

        assertSame(original, patchNotificationContent(original, null, null))
        val patched = patchNotificationContent(original, title = null, text = "")
        val notification = patched["notification"] as? Map<*, *>
            ?: error("notification must remain a map")
        assertEquals("", notification["text"])
    }

    @Test
    fun `partial config update preserves existing notification fields`() {
        val current = mapOf<String, Any>(
            "notification" to mapOf(
                "title" to "Old",
                "smallIcon" to "tracking",
                "actions" to listOf("PAUSE"),
                "importance" to 2,
            ),
        )
        val incoming = mapOf<String, Any>(
            "notification" to mapOf("title" to "Trip"),
        )

        val merged = mergeConfigSnapshot(current, incoming)
        val notification = merged["notification"] as? Map<*, *>
            ?: error("notification must remain a map")

        assertEquals("Trip", notification["title"])
        assertEquals("tracking", notification["smallIcon"])
        assertEquals(listOf("PAUSE"), notification["actions"])
        assertEquals(2, notification["importance"])
    }

    @Test
    fun `partial config update preserves omitted privacy mode`() {
        val merged = mergeConfigSnapshot(
            current = mapOf("privacyModeEnabled" to true, "distanceFilter" to 25),
            incoming = mapOf("distanceFilter" to 50),
        )

        assertEquals(true, merged["privacyModeEnabled"])
        assertEquals(50, merged["distanceFilter"])
    }

    @Test
    fun `partial config update preserves explicit privacy choice`() {
        val enabled = mergeConfigSnapshot(
            current = emptyMap(),
            incoming = mapOf("privacyModeEnabled" to true),
        )
        val disabled = mergeConfigSnapshot(
            current = mapOf("privacyModeEnabled" to true),
            incoming = mapOf("privacyModeEnabled" to false),
        )

        assertEquals(true, enabled["privacyModeEnabled"])
        assertEquals(false, disabled["privacyModeEnabled"])
    }
}
