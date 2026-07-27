package com.aispotlight.android.settings

import android.content.Context
import android.content.SharedPreferences
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import com.aispotlight.android.core.ProviderID
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * API key storage backed by the Android Keystore: values are AES/GCM-encrypted
 * with a hardware-backed key and persisted in SharedPreferences (IV + ciphertext).
 * The Android analog of the macOS Keychain bundle in `APIKeyStore.swift`.
 */
object ApiKeyStore {
    // Legacy alias from before the Cuate rename — MUST stay: a new alias
    // means a new Keystore key, and every stored ciphertext becomes
    // undecryptable (users would lose all their API keys).
    private const val KEYSTORE_ALIAS = "aispotlight-api-keys"
    private const val PREFS_NAME = "api_keys_encrypted"

    /** STT-only / addon services that have their own key slot. */
    enum class AuxKey(val id: String) {
        DEEPGRAM("deepgram"),
        BRAVE("brave"),
        FAL("fal"),
        /** Hermes gateway API_SERVER_KEY (the agent addon). */
        HERMES("hermes"),
        /** Hermes dashboard session token (file uploads to the agent's host). */
        HERMES_DASHBOARD("hermesDashboard");
    }

    private lateinit var prefs: SharedPreferences
    /** In-memory presence cache — safe to consult from composables. */
    private val presenceCache = mutableMapOf<String, Boolean>()

    fun init(context: Context) {
        prefs = context.applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
    }

    // MARK: - Provider keys

    fun key(provider: ProviderID): String? = read("provider." + provider.id)

    fun setKey(provider: ProviderID, value: String?) = write("provider." + provider.id, value)

    fun hasKey(provider: ProviderID): Boolean = has("provider." + provider.id)

    // MARK: - Aux keys

    fun auxKey(aux: AuxKey): String? = read("aux." + aux.id)

    fun setAuxKey(aux: AuxKey, value: String?) = write("aux." + aux.id, value)

    fun hasAuxKey(aux: AuxKey): Boolean = has("aux." + aux.id)

    // MARK: - Crypto plumbing

    private fun has(name: String): Boolean =
        presenceCache.getOrPut(name) { prefs.contains(name) }

    private fun read(name: String): String? {
        val stored = prefs.getString(name, null) ?: return null
        return try {
            val parts = stored.split(":", limit = 2)
            val iv = Base64.decode(parts[0], Base64.NO_WRAP)
            val ciphertext = Base64.decode(parts[1], Base64.NO_WRAP)
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, secretKey(), GCMParameterSpec(128, iv))
            String(cipher.doFinal(ciphertext), Charsets.UTF_8)
        } catch (_: Exception) {
            null
        }
    }

    private fun write(name: String, value: String?) {
        val trimmed = value?.trim()
        if (trimmed.isNullOrEmpty()) {
            prefs.edit().remove(name).apply()
            presenceCache[name] = false
            return
        }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, secretKey())
        val ciphertext = cipher.doFinal(trimmed.toByteArray(Charsets.UTF_8))
        val stored = Base64.encodeToString(cipher.iv, Base64.NO_WRAP) + ":" +
            Base64.encodeToString(ciphertext, Base64.NO_WRAP)
        prefs.edit().putString(name, stored).apply()
        presenceCache[name] = true
    }

    private fun secretKey(): SecretKey {
        val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (keyStore.getKey(KEYSTORE_ALIAS, null) as? SecretKey)?.let { return it }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        generator.init(
            KeyGenParameterSpec.Builder(
                KEYSTORE_ALIAS,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .build()
        )
        return generator.generateKey()
    }
}
