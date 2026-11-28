package com.dzeroth.dzeroth

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.ContentValues
import android.os.Build
import android.os.Bundle
import android.provider.MediaStore
import android.net.Uri
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMethodCodec
import java.io.File
import java.io.OutputStream

class MainActivity : FlutterFragmentActivity() {
    private var vaultKeyChannel: VaultKeyChannel? = null
    private var galleryChannel: MethodChannel? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        createSocialChannel()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine) // registers the plugins
        vaultKeyChannel?.dispose()
        vaultKeyChannel = VaultKeyChannel(this, flutterEngine.dartExecutor.binaryMessenger)
        galleryChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "dzeroth/photo_gallery",
            StandardMethodCodec.INSTANCE,
            flutterEngine.dartExecutor.binaryMessenger.makeBackgroundTaskQueue(),
        ).apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "available" -> result.success(Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q)
                    "saveJpeg" -> {
                        val jpeg = call.arguments as? ByteArray
                        if (jpeg == null || Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
                            result.error("gallery_unavailable", "Gallery export is unavailable.", null)
                        } else {
                            try {
                                saveMedia(
                                    MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
                                    "image/jpeg", "Pictures/Dzeroth", "jpg",
                                ) { it.write(jpeg) }
                                result.success(null)
                            } catch (error: Exception) {
                                result.error("gallery_write", "Could not save the photo.", null)
                            }
                        }
                    }
                    "saveMp4" -> {
                        val path = call.arguments as? String
                        if (path == null || Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
                            result.error("gallery_unavailable", "Gallery export is unavailable.", null)
                        } else {
                            try {
                                val clip = File(path).canonicalFile
                                check(clip.toPath().startsWith(cacheDir.canonicalFile.toPath()))
                                saveMedia(
                                    MediaStore.Video.Media.EXTERNAL_CONTENT_URI,
                                    "video/mp4", "Movies/Dzeroth", "mp4",
                                ) { output -> clip.inputStream().use { it.copyTo(output) } }
                                result.success(null)
                            } catch (error: Exception) {
                                result.error("gallery_write", "Could not save the video.", null)
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        vaultKeyChannel?.dispose()
        vaultKeyChannel = null
        galleryChannel?.setMethodCallHandler(null)
        galleryChannel = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    @android.annotation.TargetApi(Build.VERSION_CODES.Q)
    private fun saveMedia(
        collection: Uri,
        mimeType: String,
        directory: String,
        extension: String,
        write: (OutputStream) -> Unit,
    ) {
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, "Dzeroth-${System.currentTimeMillis()}.$extension")
            put(MediaStore.MediaColumns.MIME_TYPE, mimeType)
            put(MediaStore.MediaColumns.RELATIVE_PATH, directory)
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }
        val uri = contentResolver.insert(collection, values)
            ?: error("Could not create gallery item")
        try {
            val stream = contentResolver.openOutputStream(uri) ?: error("Could not open gallery item")
            stream.use(write)
            val published = ContentValues().apply {
                put(MediaStore.MediaColumns.IS_PENDING, 0)
            }
            check(contentResolver.update(uri, published, null, null) == 1)
        } catch (error: Exception) {
            contentResolver.delete(uri, null, null)
            throw error
        }
    }

    /**
     * The backend sends every push with channel id "social"
     * (backend/internal/notifications/fcm.go). Android 8+ drops the channel
     * choice and falls back to a generic one unless it exists, so create it
     * at startup (idempotent).
     */
    private fun createSocialChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java) ?: return
        val channel = NotificationChannel(
            "social",
            "Activity",
            NotificationManager.IMPORTANCE_DEFAULT,
        ).apply {
            description = "Follows, replies, likes, mentions and reposts"
        }
        manager.createNotificationChannel(channel)
    }
}
