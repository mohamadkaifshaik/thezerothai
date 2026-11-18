package com.dzeroth.dzeroth

import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyPermanentlyInvalidatedException
import android.security.keystore.KeyProperties
import android.util.Base64
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.security.KeyStore
import java.security.ProviderException
import java.security.UnrecoverableKeyException
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import javax.crypto.AEADBadTagException
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * The vault's storage key (lib/core/vault/vault_cipher_android.dart).
 *
 * Dart makes a random 32-byte data key; this class wraps it with an AES-256-GCM
 * key in the AndroidKeyStore (non-exportable, no user authentication, StrongBox
 * when the device has it, else the TEE) and keeps the wrapped form in the
 * private SharedPreferences file `dzeroth_vault_keys`. That file is covered by
 * the manifest's allowBackup="false" and by data_extraction_rules.xml (the
 * whole "sharedpref" domain is excluded), so it never leaves the device.
 *
 * Channel `dzeroth/vault_key`, every argument a map:
 *
 *   wrap   {alias: String, dataKey: ByteArray(32)} -> null
 *          Deletes any Keystore key under alias, generates a new one, encrypts
 *          dataKey (the Keystore picks the IV) and stores
 *          base64(iv(12) || ciphertext || tag(16)) under alias. Replies after
 *          SharedPreferences.commit() reports the write done.
 *   unwrap {alias: String} -> ByteArray (the data key)
 *   delete {alias: String} -> null (idempotent; Keystore key and stored value)
 *
 * Error codes (message is fixed text, details always null; no key bytes and no
 * exception message ever goes back):
 *   no_key       unwrap: the preferences hold no value for alias.
 *   key_lost     unwrap: a value is stored but cannot be unwrapped: Keystore
 *                alias missing, KeyPermanentlyInvalidatedException,
 *                UnrecoverableKeyException, AEADBadTagException, malformed value.
 *   unavailable  anything else (Keystore or storage not usable, bad arguments).
 *
 * Keystore work runs on one background thread, one call at a time; every reply
 * is posted to the main thread exactly once.
 */
class VaultKeyChannel(context: Context, messenger: BinaryMessenger) {
    private val appContext = context.applicationContext
    private val channel = MethodChannel(messenger, CHANNEL)
    private val executor: ExecutorService = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())

    init {
        channel.setMethodCallHandler(::onMethodCall)
    }

    /** Stops answering; queued work still finishes but its replies are dropped. */
    fun dispose() {
        channel.setMethodCallHandler(null)
        executor.shutdown()
    }

    private fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val alias = call.argument<String>("alias")
        if (alias == null || !alias.startsWith(ALIAS_PREFIX)) {
            result.error(UNAVAILABLE, "bad arguments", null)
            return
        }
        val dataKey = if (call.method == "wrap") call.argument<ByteArray>("dataKey") else null
        try {
            executor.execute {
                val reply: Reply = try {
                    when (call.method) {
                        "wrap" -> {
                            if (dataKey == null || dataKey.size != DATA_KEY_BYTES) {
                                Reply.Error(UNAVAILABLE, "bad arguments")
                            } else {
                                wrap(alias, dataKey)
                                Reply.Success(null)
                            }
                        }
                        "unwrap" -> unwrap(alias)
                        "delete" -> {
                            delete(alias)
                            Reply.Success(null)
                        }
                        else -> Reply.NotImplemented
                    }
                } catch (e: Throwable) {
                    Reply.Error(UNAVAILABLE, "key store unavailable")
                } finally {
                    dataKey?.fill(0)
                }
                mainHandler.post {
                    when (reply) {
                        is Reply.Success -> {
                            result.success(reply.value) // encodes the reply now
                            (reply.value as? ByteArray)?.fill(0)
                        }
                        is Reply.Error -> result.error(reply.code, reply.message, null)
                        Reply.NotImplemented -> result.notImplemented()
                    }
                }
            }
        } catch (e: Exception) {
            // Executor shut down (engine detached) or rejected the task.
            dataKey?.fill(0)
            result.error(UNAVAILABLE, "key store unavailable", null)
        }
    }

    private fun prefs() = appContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    private fun keyStore(): KeyStore = KeyStore.getInstance(KEYSTORE).apply { load(null) }

    private fun wrap(alias: String, dataKey: ByteArray) {
        val store = keyStore()
        if (store.containsAlias(alias)) store.deleteEntry(alias)
        val key = generateKey(alias)
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, key) // randomized: the Keystore picks the IV
        val iv = cipher.iv
        val sealed = cipher.doFinal(dataKey)
        check(iv.size == IV_BYTES)
        val wrapped = ByteArray(iv.size + sealed.size)
        System.arraycopy(iv, 0, wrapped, 0, iv.size)
        System.arraycopy(sealed, 0, wrapped, iv.size, sealed.size)
        val ok = prefs().edit()
            .putString(alias, Base64.encodeToString(wrapped, Base64.NO_WRAP))
            .commit()
        if (!ok) throw IllegalStateException("write failed")
    }

    private fun unwrap(alias: String): Reply {
        val encoded = prefs().getString(alias, null)
            ?: return Reply.Error(NO_KEY, "no stored key")
        val wrapped = try {
            Base64.decode(encoded, Base64.NO_WRAP)
        } catch (e: IllegalArgumentException) {
            return Reply.Error(KEY_LOST, "key lost")
        }
        if (wrapped.size != IV_BYTES + DATA_KEY_BYTES + TAG_BYTES) {
            return Reply.Error(KEY_LOST, "key lost")
        }
        return try {
            val key = keyStore().getKey(alias, null) as? SecretKey
                ?: return Reply.Error(KEY_LOST, "key lost")
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(TAG_BYTES * 8, wrapped, 0, IV_BYTES))
            Reply.Success(cipher.doFinal(wrapped, IV_BYTES, wrapped.size - IV_BYTES))
        } catch (e: KeyPermanentlyInvalidatedException) {
            Reply.Error(KEY_LOST, "key lost")
        } catch (e: UnrecoverableKeyException) {
            Reply.Error(KEY_LOST, "key lost")
        } catch (e: AEADBadTagException) {
            Reply.Error(KEY_LOST, "key lost")
        }
        // Everything else (ProviderException, KeyStoreException, ...) is
        // unavailable, mapped by the caller.
    }

    private fun delete(alias: String) {
        val store = keyStore()
        if (store.containsAlias(alias)) store.deleteEntry(alias)
        val ok = prefs().edit().remove(alias).commit()
        if (!ok) throw IllegalStateException("write failed")
    }

    private fun generateKey(alias: String): SecretKey {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            val strongBox = generateStrongBoxKey(alias)
            if (strongBox != null) return strongBox
        }
        return keyGenerator(spec(alias).build())
    }

    /**
     * API 28+. Null when the device has no StrongBox (StrongBoxUnavailableException,
     * a ProviderException) or StrongBox refuses the key, after removing any
     * half-made entry, so the caller silently falls back to the TEE.
     */
    private fun generateStrongBoxKey(alias: String): SecretKey? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) return null
        return try {
            keyGenerator(spec(alias).setIsStrongBoxBacked(true).build())
        } catch (e: ProviderException) {
            val store = keyStore()
            if (store.containsAlias(alias)) store.deleteEntry(alias)
            null
        }
    }

    private fun spec(alias: String) = KeyGenParameterSpec.Builder(
        alias,
        KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
    )
        .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
        .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
        .setKeySize(256)
        .setRandomizedEncryptionRequired(true)
        .setUserAuthenticationRequired(false)

    private fun keyGenerator(spec: KeyGenParameterSpec): SecretKey =
        KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, KEYSTORE).run {
            init(spec)
            generateKey()
        }

    private sealed class Reply {
        class Success(val value: Any?) : Reply()
        class Error(val code: String, val message: String) : Reply()
        object NotImplemented : Reply()
    }

    companion object {
        const val CHANNEL = "dzeroth/vault_key"
        private const val PREFS = "dzeroth_vault_keys"
        private const val KEYSTORE = "AndroidKeyStore"
        private const val TRANSFORMATION = "AES/GCM/NoPadding"
        private const val ALIAS_PREFIX = "dzeroth.vault."
        private const val DATA_KEY_BYTES = 32
        private const val IV_BYTES = 12
        private const val TAG_BYTES = 16
        private const val NO_KEY = "no_key"
        private const val KEY_LOST = "key_lost"
        private const val UNAVAILABLE = "unavailable"
    }
}
