package de.cbfunk.cb_funk

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager

class BackgroundAudioService : Service() {
    private var audioWakeLock: PowerManager.WakeLock? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        isRunning = true
        val notification = buildNotification()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        acquireAudioWakeLock()
        return START_STICKY
    }

    private fun acquireAudioWakeLock() {
        val lock = audioWakeLock ?: run {
            val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
            powerManager.newWakeLock(
                PowerManager.PARTIAL_WAKE_LOCK,
                "CBFunk:AudioStream"
            ).apply {
                setReferenceCounted(false)
            }.also { audioWakeLock = it }
        }
        if (!lock.isHeld) lock.acquire()
    }

    override fun onCreate() {
        super.onCreate()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "CB-Funk im Hintergrund",
                NotificationManager.IMPORTANCE_LOW
            )
            getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
        }
    }

    private fun buildNotification(): Notification {
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setContentTitle("CB-Funk aktiv")
            .setContentText("Empfang läuft im Hintergrund")
            .setSmallIcon(android.R.drawable.ic_media_play)
            .setCategory(Notification.CATEGORY_SERVICE)
            .setOngoing(true)
            .build()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        isRunning = false
        audioWakeLock?.let { if (it.isHeld) it.release() }
        audioWakeLock = null
        super.onDestroy()
    }

    companion object {
        @Volatile
        var isRunning = false
            private set

        private const val CHANNEL_ID = "cbfunk_background_audio"
        private const val NOTIFICATION_ID = 1101
    }
}