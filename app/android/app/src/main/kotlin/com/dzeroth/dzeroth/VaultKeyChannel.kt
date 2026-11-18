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
import java.security.InvalidKeyException
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
 *          Create-if-absent: when a value is already stored under alias it
 *          answers `exists` and changes nothing. Otherwise it generates a new
 *          Keystore key under alias, encrypts dataKey (the Keystore picks the
 *          IV) and then stores base64(iv(12) || ciphertext || tag(16)) under
 *          alias. A Keystore key already under alias without a stored value
 *          is not deleted first: generateKey replaces the alias, and that old
 *          key was unreachable (it wrapped nothing that is stored). A failure
 *          before the write leaves no stored value. Replies after
 *          SharedPreferences.commit() reports the write done.
 *   unwrap {alias: String} -> ByteArray (the data key). An attempt that would
 *          answer `unavailable`, or that finds getKey == null, is retried
 *          once after RETRY_DELAY_MS on the worker thread.
 *   delete {alias: String} -> null (idempotent). The stored value is removed
 *          first, then the Keystore key, so no path leaves a stored value
 *          without its key.
 *   any other method -> notImplemented
 *
 * wrap, unwrap and delete hold one process-wide lock (companion LOCK), so two
 * FlutterEngines (two instances of this class) never interleave.
 *
 * Error codes (message is fixed text, details always null; no key bytes and no
 * exception message ever goes back):
 *   no_key       unwrap: the preferences hold no value for alias.
 *   exists       wrap: a value is already stored for alias; nothing changed.
 *   key_lost     unwrap: a value is stored but the key is gone for good:
 *                - getKey returns null on both attempts AND containsAlias(alias)
 *                  is false after the second (true, or a throw: unavailable);
 *                - the stored value is not base64 or has the wrong length;
 *                - AEADBadTagException (the stored value does not authenticate);
 *                - KeyPermanentlyInvalidatedException, thrown or anywhere in
 *                  the cause chain;
 *                - UnrecoverableKeyException (getKey) or InvalidKeyException
 *                  (Cipher.init) whose cause chain holds, on API 33+, an
 *                  android.security.KeyStoreException that is permanent
 *                  (!isTransientFailure && !isSystemError) with code
 *                  ERROR_KEY_DOES_NOT_EXIST or ERROR_KEY_CORRUPTED.
 *   unavailable  everything else, after the retry: any other
 *                UnrecoverableKeyException or InvalidKeyException,
 *                ProviderException, KeyStoreException, storage failures,
 *                bad arguments (wrong type or size). A transient failure is
 *                never key_lost, because Dart treats key_lost as data loss.
 *
 * Only the activity's FlutterEngine registers this channel (MainActivity). A
 * background FlutterEngine (the FCM background isolate) has no handler, so a
 * call there fails with MissingPluginException, which Dart reports as
 * unavailable.
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
        if (call.method != "wrap" && call.method != "unwrap" && call.method != "delete") {
            result.notImplemented()
            return
        }
        // Safe casts only: a wrong type is "bad arguments", never exception text.
        val args = call.arguments as? Map<*, *>
        val alias = args?.get("alias") as? String
        val dataKey = if (call.method == "wrap") args?.get("dataKey") as? ByteArray else null
        if (alias == null || !alias.startsWith(ALIAS_PREFIX) ||
            (call.method == "wrap" && (dataKey == null || dataKey.size != DATA_KEY_BYTES))
        ) {
            dataKey?.fill(0)
            result.error(UNAVAILABLE, "bad arguments", null)
            return
        }
        try {
            executor.execute {
                val reply: Reply = try {
                    // One lock for the whole process: two engines (two
                    // VaultKeyChannel instances) never interleave on an alias.
                    synchronized(LOCK) {
                        when (call.method) {
                            "wrap" -> wrap(alias, dataKey!!)
                            "unwrap" -> unwrapWithRetry(alias)
                            else -> {
                                delete(alias)
                                Reply.Success(null)
                            }
                        }
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

    private fun wrap(alias: String, dataKey: ByteArray): Reply {
        val prefs = prefs()
        if (prefs.contains(alias)) return Reply.Error(EXISTS, "already stored")
        // A Keystore key left under alias without a stored value is not
        // deleted first: generateKey replaces the alias, and the old key was
        // unreachable anyway (it wraps nothing that is stored). The value is
        // written only after the new key exists and has wrapped dataKey.
        val key = generateKey(alias)
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, key) // randomized: the Keystore picks the IV
        val iv = cipher.iv
        val sealed = cipher.doFinal(dataKey)
        check(iv.size == IV_BYTES)
        val wrapped = ByteArray(iv.size + sealed.size)
        System.arraycopy(iv, 0, wrapped, 0, iv.size)
        System.arraycopy(sealed, 0, wrapped, iv.size, sealed.size)
        val ok = prefs.edit()
            .putString(alias, Base64.encodeToString(wrapped, Base64.NO_WRAP))
            .commit()
        if (!ok) throw IllegalStateException("write failed")
        return Reply.Success(null)
    }

    private fun unwrapWithRetry(alias: String): Reply {
        val first = unwrapClassified(alias)
        if (!first.isRetryable()) return first
        Thread.sleep(RETRY_DELAY_MS) // the worker thread, never the main thread
        val second = unwrapClassified(alias)
        if (second !is Reply.Error || second.code != KEY_MISSING) return second
        if ((first as Reply.Error).code != KEY_MISSING) {
            return Reply.Error(UNAVAILABLE, "key store unavailable")
        }
        // getKey returned null on both attempts. On API 24-30 a transient
        // Keystore failure can look like that, so it is key_lost only when
        // the Keystore also says the alias is not there.
        return try {
            if (keyStore().containsAlias(alias)) {
                Reply.Error(UNAVAILABLE, "key store unavailable")
            } else {
                Reply.Error(KEY_LOST, "key lost")
            }
        } catch (e: Exception) {
            Reply.Error(UNAVAILABLE, "key store unavailable")
        }
    }

    private fun Reply.isRetryable() =
        this is Reply.Error && (code == UNAVAILABLE || code == KEY_MISSING)

    private fun unwrapClassified(alias: String): Reply = try {
        unwrap(alias)
    } catch (e: Exception) {
        if (isKeyGone(e)) Reply.Error(KEY_LOST, "key lost") else Reply.Error(UNAVAILABLE, "key store unavailable")
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
        // Null: maybe gone, maybe transient; unwrapWithRetry decides.
        val key = keyStore().getKey(alias, null) as? SecretKey
            ?: return Reply.Error(KEY_MISSING, "key missing")
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(TAG_BYTES * 8, wrapped, 0, IV_BYTES))
        return try {
            Reply.Success(cipher.doFinal(wrapped, IV_BYTES, wrapped.size - IV_BYTES))
        } catch (e: AEADBadTagException) {
            Reply.Error(KEY_LOST, "key lost")
        }
        // Everything else is classified by isKeyGone in unwrapClassified.
    }

    /** Whether [e] means the Keystore key is gone for good (see the header). */
    private fun isKeyGone(e: Throwable): Boolean {
        if (causeChain(e).any { it is KeyPermanentlyInvalidatedException }) return true
        // getKey throws UnrecoverableKeyException, Cipher.init InvalidKeyException.
        if (e !is UnrecoverableKeyException && e !is InvalidKeyException) return false
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return false
        return causeChain(e).any { isPermanentKeyStoreFailure(it) }
    }

    /** API 33+ only: android.security.KeyStoreException exists from 33. */
    private fun isPermanentKeyStoreFailure(t: Throwable): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return false
        if (t !is android.security.KeyStoreException) return false
        if (t.isTransientFailure || t.isSystemError) return false
        return t.numericErrorCode == android.security.KeyStoreException.ERROR_KEY_DOES_NOT_EXIST ||
            t.numericErrorCode == android.security.KeyStoreException.ERROR_KEY_CORRUPTED
    }

    private fun causeChain(e: Throwable): Sequence<Throwable> =
        generateSequence(e) { t -> t.cause?.takeIf { it !== t } }.take(MAX_CAUSE_DEPTH)

    private fun delete(alias: String) {
        // The stored value goes first: a failure after it leaves at most an
        // unreachable Keystore key, never a stored value without its key
        // (which the next unwrap would report as key_lost).
        val ok = prefs().edit().remove(alias).commit()
        if (!ok) throw IllegalStateException("write failed")
        val store = keyStore()
        if (store.containsAlias(alias)) store.deleteEntry(alias)
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
            // Nothing to clean up: the TEE generation replaces the alias, and
            // no value is stored for it until that key has wrapped dataKey.
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
        private const val RETRY_DELAY_MS = 250L
        private const val MAX_CAUSE_DEPTH = 16
        private const val NO_KEY = "no_key"
        private const val EXISTS = "exists"
        private const val KEY_LOST = "key_lost"
        private const val UNAVAILABLE = "unavailable"

        // Internal only, never sent: getKey returned null (see unwrapWithRetry).
        private const val KEY_MISSING = "key_missing"

        // Serializes wrap, unwrap and delete across every instance in the process.
        private val LOCK = Any()
    }
}
