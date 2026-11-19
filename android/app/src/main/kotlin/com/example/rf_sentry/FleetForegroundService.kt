package com.example.rf_sentry

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat

/**
 * Fleet foreground service (v0.28.0, spec §8).
 *
 * Keeps the fleet beacon/listener socket alive with a persistent
 * notification ("Outride Fleet — N members") while the operator is
 * in a fleet. Started when the operator opens Fleet / joins or
 * creates, stopped on "Forget fleet" (Dart side:
 * fleet_foreground.dart, channel `outride/fleet_service`).
 *
 * No new runtime permission: the Android 13+ notification
 * permission, if denied, only hides the notification — the service
 * still runs, with no blocking prompt.
 *
 * NOTE: written without an Android SDK on the build machine, so it
 * has never been compiled — same standing as the Wi-Fi Aware block
 * in MainActivity.kt. If `flutter build apk` fails, this file plus
 * the FLEET block in configureFlutterEngine are the first suspects:
 * deleting them leaves the Dart fleet service running without the
 * persistent notification (it degrades, it does not break).
 */
class FleetForegroundService : Service() {
    companion object {
        private const val CHANNEL_ID = "outride_fleet"
        private const val NOTIF_ID = 6970
        private const val ACTION_START = "com.example.rf_sentry.FLEET_START"
        private const val ACTION_STOP = "com.example.rf_sentry.FLEET_STOP"
        private const val EXTRA_MEMBERS = "members"

        fun startIntent(context: Context, members: Int): Intent =
            Intent(context, FleetForegroundService::class.java).apply {
                action = ACTION_START
                putExtra(EXTRA_MEMBERS, members)
            }

        fun stopIntent(context: Context): Intent =
            Intent(context, FleetForegroundService::class.java).apply {
                action = ACTION_STOP
            }
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(Context.NOTIFICATION_SERVICE)
            as? NotificationManager ?: return
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "Outride Fleet",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "Fleet meshing is running"
        }
        manager.createNotificationChannel(channel)
    }

    private fun buildNotification(members: Int): Notification {
        createChannel()
        val text = if (members <= 1) {
            "Outride Fleet — listening"
        } else {
            "Outride Fleet — $members members"
        }
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setContentTitle("Outride Fleet")
            .setContentText(text)
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
                return START_NOT_STICKY
            }
            else -> {
                val members = intent?.getIntExtra(EXTRA_MEMBERS, 0) ?: 0
                val notification = buildNotification(members)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    startForeground(
                        NOTIF_ID,
                        notification,
                        ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
                    )
                } else {
                    startForeground(NOTIF_ID, notification)
                }
                return START_STICKY
            }
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
