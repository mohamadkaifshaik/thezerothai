package com.dzeroth.dzeroth

import android.app.NotificationChannel
import android.app.NotificationManager
import android.os.Build
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        createSocialChannel()
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
