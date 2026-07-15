package dev.locus.core

import android.content.SharedPreferences
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import java.nio.charset.StandardCharsets
import java.security.KeyStore
import java.util.Base64
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

internal data class ConfigSnapshotReadResult(
    val serialized: String? = null,
    val isLegacyPlaintext: Boolean = false,
    val error: Exception? = null,
)

internal data class ConfigSnapshotWriteResult(
    val success: Boolean,
    val error: Exception? = null,
)

internal data class EncryptedConfigSnapshot(
    val iv: ByteArray,
    val ciphertext: ByteArray,
)

/** Versioned, context-free envelope codec kept independently unit-testable. */
internal object ConfigSnapshotEnvelope {
    internal const val PREFIX = "locus:v1:"

    fun encode(snapshot: EncryptedConfigSnapshot): String {
        require(snapshot.iv.size == SecureConfigSnapshotStore.GCM_IV_BYTES) {
            "Config snapshot IV must be ${SecureConfigSnapshotStore.GCM_IV_BYTES} bytes"
        }
        require(snapshot.ciphertext.isNotEmpty()) { "Config snapshot ciphertext must not be empty" }

        val encoder = Base64.getUrlEncoder().withoutPadding()
        return buildString {
            append(PREFIX)
            append(encoder.encodeToString(snapshot.iv))
            append(':')
            append(encoder.encodeToString(snapshot.ciphertext))
        }
    }

    /** Returns `null` only for a legacy plaintext value. */
    fun decode(serialized: String): EncryptedConfigSnapshot? {
        if (!serialized.startsWith(PREFIX)) return null

        val components = serialized.removePrefix(PREFIX).split(':')
        require(components.size == 2 && components.none { it.isEmpty() }) {
            "Malformed encrypted config snapshot envelope"
        }

        val decoder = Base64.getUrlDecoder()
        val iv = decoder.decode(components[0])
        val ciphertext = decoder.decode(components[1])
        require(iv.size == SecureConfigSnapshotStore.GCM_IV_BYTES) {
            "Malformed encrypted config snapshot IV"
        }
        require(ciphertext.isNotEmpty()) { "Malformed encrypted config snapshot ciphertext" }
        return EncryptedConfigSnapshot(iv, ciphertext)
    }
}

/**
 * Owns encrypted persistence for the recovery configuration snapshot.
 *
 * Existing releases stored raw JSON under the same preference key. Reads remain
 * compatible with that format so [ConfigManager] can migrate it after successful
 * decoding. Every write is encrypted first; encryption failure never falls back
 * to plaintext.
 */
internal class SecureConfigSnapshotStore(
    private val preferences: SharedPreferences,
    private val preferenceKey: String,
) {
    fun read(): ConfigSnapshotReadResult {
        val stored = preferences.getString(preferenceKey, null)
            ?: return ConfigSnapshotReadResult()

        return try {
            val encrypted = ConfigSnapshotEnvelope.decode(stored)
                ?: return ConfigSnapshotReadResult(
                    serialized = stored,
                    isLegacyPlaintext = true,
                )
            ConfigSnapshotReadResult(serialized = decrypt(encrypted))
        } catch (error: Exception) {
            ConfigSnapshotReadResult(error = error)
        }
    }

    fun write(
        serialized: String,
        mutate: SharedPreferences.Editor.() -> Unit = {},
    ): ConfigSnapshotWriteResult {
        return try {
            val encrypted = encrypt(serialized)
            val editor = preferences.edit()
                .putString(preferenceKey, ConfigSnapshotEnvelope.encode(encrypted))
                .apply(mutate)
            val committed = editor.commit()
            ConfigSnapshotWriteResult(success = committed)
        } catch (error: Exception) {
            ConfigSnapshotWriteResult(success = false, error = error)
        }
    }

    private fun encrypt(serialized: String): EncryptedConfigSnapshot {
        val cipher = Cipher.getInstance(TRANSFORMATION).apply {
            // AndroidKeyStore rejects caller-provided IVs when randomized encryption
            // is required. Let the provider generate the IV and persist it with the
            // ciphertext for decryption.
            init(Cipher.ENCRYPT_MODE, getOrCreateKey())
            updateAAD(aad())
        }
        val iv = cipher.iv
        check(iv.size == GCM_IV_BYTES) { "AndroidKeyStore returned an invalid GCM IV" }
        return EncryptedConfigSnapshot(
            iv = iv,
            ciphertext = cipher.doFinal(serialized.toByteArray(StandardCharsets.UTF_8)),
        )
    }

    private fun decrypt(snapshot: EncryptedConfigSnapshot): String {
        val cipher = Cipher.getInstance(TRANSFORMATION).apply {
            init(
                Cipher.DECRYPT_MODE,
                getOrCreateKey(),
                GCMParameterSpec(GCM_TAG_BITS, snapshot.iv),
            )
            updateAAD(aad())
        }
        return String(cipher.doFinal(snapshot.ciphertext), StandardCharsets.UTF_8)
    }

    private fun aad(): ByteArray =
        "$KEY_ALIAS:$preferenceKey:v1".toByteArray(StandardCharsets.UTF_8)

    private fun getOrCreateKey(): SecretKey {
        synchronized(KEY_CREATION_LOCK) {
            val keyStore = KeyStore.getInstance(KEYSTORE_PROVIDER).apply { load(null) }
            (keyStore.getKey(KEY_ALIAS, null) as? SecretKey)?.let { return it }

            val generator = KeyGenerator.getInstance(
                KeyProperties.KEY_ALGORITHM_AES,
                KEYSTORE_PROVIDER,
            )
            generator.init(
                KeyGenParameterSpec.Builder(
                    KEY_ALIAS,
                    KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
                )
                    .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                    .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                    .setKeySize(KEY_SIZE_BITS)
                    .setRandomizedEncryptionRequired(true)
                    .build(),
            )
            return generator.generateKey()
        }
    }

    companion object {
        internal const val GCM_IV_BYTES = 12

        private const val KEYSTORE_PROVIDER = "AndroidKeyStore"
        private const val KEY_ALIAS = "dev.locus.config_snapshot.v1"
        private const val TRANSFORMATION = "AES/GCM/NoPadding"
        private const val GCM_TAG_BITS = 128
        private const val KEY_SIZE_BITS = 256
        private val KEY_CREATION_LOCK = Any()
    }
}
