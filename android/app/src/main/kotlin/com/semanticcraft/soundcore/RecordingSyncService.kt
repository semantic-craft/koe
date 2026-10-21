package com.semanticcraft.soundcore

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.IBinder
import android.os.PowerManager
import android.util.Log

/**
 * Koe's one foreground service. It keeps the process, and with it the Dart
 * BLE session, alive while work runs behind the lock screen. The work itself
 * stays in Dart; this only holds the foreground state, the notification and
 * a partial wake lock.
 *
 * Dart sends the full state on every change: the service types of all active
 * works (connectedDevice for recorder sync, microphone for phone recording
 * and listening), the notification text, and whether the notification offers
 * 停止. The service runs as their union. 停止 only asks Dart to finish the
 * microphone work (save the take, keep the text); Dart then ends it as usual.
 *
 * Android 14+ crashes the process when a startForegroundService() start is
 * not followed by a successful startForeground(), so a rejected type falls
 * back to shortService (no permission needed) before stopping, and stop is
 * queued behind pending starts instead of calling stopService() directly.
 * Pattern from omi's SyncTransferForegroundService and ForegroundStartContract.
 */
class RecordingSyncService : Service() {
    private var wakeLock: PowerManager.WakeLock? = null
    private var appliedTypes = 0

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
        instance = this
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_USER_STOP) {
            // Delivered by startService from the notification, so there is no
            // pending foreground promotion to satisfy here.
            val listener = stopListener
            if (listener == null || requestedTypes == 0) {
                // No Dart side left to finish the work (the activity is
                // gone): only the notification remains, so take it down.
                requestedTypes = 0
                shutDown()
            } else {
                listener()
            }
            return START_NOT_STICKY
        }
        if (intent?.action == ACTION_STOP || requestedTypes == 0) {
            // A start may already be waiting for its foreground promotion;
            // satisfy it before stopping, or Android ends the process.
            if (appliedTypes == 0) promoteShortService()
            shutDown()
            return START_NOT_STICKY
        }
        if (!apply()) {
            shutDown()
            return START_NOT_STICKY
        }
        acquireWakeLock()
        return START_NOT_STICKY
    }

    /** Brings foreground types and notification in line with the request. */
    private fun apply(): Boolean {
        val types = requestedTypes
        val notification = buildNotification(requestedText, requestedStoppable)
        if (types == appliedTypes) {
            getSystemService(NotificationManager::class.java).notify(NOTIFICATION_ID, notification)
            return true
        }
        return try {
            startForeground(NOTIFICATION_ID, notification, types)
            appliedTypes = types
            true
        } catch (error: Exception) {
            Log.e(TAG, "startForeground($types) rejected", error)
            if (appliedTypes == 0) promoteShortService()
            false
        }
    }

    private fun promoteShortService() {
        try {
            startForeground(
                NOTIFICATION_ID,
                buildNotification(requestedText, stoppable = false),
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SHORT_SERVICE,
            )
        } catch (error: Exception) {
            Log.e(TAG, "startForeground(shortService) failed", error)
        }
    }

    private fun shutDown() {
        releaseWakeLock()
        appliedTypes = 0
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    // shortService only runs during the brief fallback above; never past
    // its time limit. connectedDevice and microphone have no time limit.
    @Deprecated("Android 14 only; Android 15+ calls the two-argument form")
    override fun onTimeout(startId: Int) {
        shutDown()
    }

    override fun onTimeout(startId: Int, fgsType: Int) {
        shutDown()
    }

    override fun onDestroy() {
        releaseWakeLock()
        if (instance === this) instance = null
        super.onDestroy()
    }

    private fun acquireWakeLock() {
        if (wakeLock?.isHeld == true) return
        val powerManager = getSystemService(POWER_SERVICE) as PowerManager
        wakeLock = powerManager.newWakeLock(
            PowerManager.PARTIAL_WAKE_LOCK,
            "$packageName:recordingSync",
        ).apply {
            setReferenceCounted(false)
            acquire()
        }
    }

    private fun releaseWakeLock() {
        wakeLock?.let { lock ->
            if (lock.isHeld) lock.release()
        }
        wakeLock = null
    }

    private fun createNotificationChannel() {
        val manager = getSystemService(NotificationManager::class.java)
        val channel = NotificationChannel(
            CHANNEL_ID,
            "后台工作",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "同步录音、手机录音和监听在后台进行时显示"
            setShowBadge(false)
            setSound(null, null)
        }
        manager.createNotificationChannel(channel)
    }

    private fun buildNotification(text: String, stoppable: Boolean): Notification {
        // The launcher intent brings the existing task back, as tapping the
        // app icon does, instead of stacking a second activity.
        val openApp = packageManager.getLaunchIntentForPackage(packageName)
            ?: Intent(this, MainActivity::class.java)
        val contentIntent = PendingIntent.getActivity(
            this,
            0,
            openApp,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val builder = Notification.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_sync_notification)
            .setContentTitle("Koe")
            .setContentText(text)
            .setCategory(Notification.CATEGORY_SERVICE)
            .setContentIntent(contentIntent)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setForegroundServiceBehavior(Notification.FOREGROUND_SERVICE_IMMEDIATE)
        if (stoppable) {
            val stop = PendingIntent.getService(
                this,
                1,
                Intent(this, RecordingSyncService::class.java).setAction(ACTION_USER_STOP),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            builder.addAction(
                Notification.Action.Builder(null, STOP_TITLE, stop).build(),
            )
        }
        return builder.build()
    }

    companion object {
        private const val TAG = "KoeForeground"
        private const val CHANNEL_ID = "recording_sync"
        private const val NOTIFICATION_ID = 3200
        private const val ACTION_STOP = "com.semanticcraft.soundcore.STOP_FOREGROUND"
        private const val ACTION_USER_STOP = "com.semanticcraft.soundcore.USER_STOP"
        private const val STOP_TITLE = "停止"
        private const val DEFAULT_TEXT = "Koe 正在后台工作"

        private val typeFlags = mapOf(
            "connectedDevice" to ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE,
            "microphone" to ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE,
        )

        // Each type needs this runtime permission at startForeground time.
        private val typePermissions = mapOf(
            "connectedDevice" to Manifest.permission.BLUETOOTH_CONNECT,
            "microphone" to Manifest.permission.RECORD_AUDIO,
        )

        @Volatile private var instance: RecordingSyncService? = null
        @Volatile private var requestedTypes = 0
        @Volatile private var requestedText = DEFAULT_TEXT
        @Volatile private var requestedStoppable = false

        /** Asks Dart to finish the stoppable work; set while Flutter runs. */
        @Volatile var stopListener: (() -> Unit)? = null

        /**
         * Runs the service as [types] with [text] on its notification.
         * Returns the types it started with; one whose permission is not yet
         * granted is left out, and the service does not start without any.
         */
        fun update(
            context: Context,
            types: List<String>,
            text: String?,
            stoppable: Boolean,
        ): List<String> {
            val usable = types.filter { name ->
                val permission = typePermissions[name] ?: return@filter false
                context.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED
            }
            if (usable.isEmpty()) {
                stop(context)
                return emptyList()
            }
            requestedTypes = usable.fold(0) { flags, name -> flags or typeFlags.getValue(name) }
            requestedText = text?.takeIf { it.isNotBlank() } ?: DEFAULT_TEXT
            requestedStoppable = stoppable
            val running = instance
            if (running != null && running.appliedTypes != 0) {
                // Already in the foreground: change it in place, which also
                // works while Koe is off screen (text updates, ending one of
                // two works). Adding a type from the background can be
                // refused; the types it keeps are reported back.
                running.apply()
                return namesOf(running.appliedTypes)
            }
            return try {
                context.startForegroundService(Intent(context, RecordingSyncService::class.java))
                usable
            } catch (error: Exception) {
                // Typically ForegroundServiceStartNotAllowedException: the
                // first start has to happen while Koe is on screen.
                Log.e(TAG, "Foreground service start refused", error)
                requestedTypes = 0
                emptyList()
            }
        }

        private fun namesOf(flags: Int): List<String> =
            typeFlags.filterValues { flag -> flags and flag != 0 }.keys.toList()

        fun stop(context: Context) {
            requestedTypes = 0
            if (instance == null) return
            try {
                // Same command queue as the starts, so a pending start gets
                // its promotion before this stop is handled.
                context.startService(
                    Intent(context, RecordingSyncService::class.java).setAction(ACTION_STOP),
                )
            } catch (error: Exception) {
                Log.w(TAG, "Queued stop refused; stopping directly", error)
                context.stopService(Intent(context, RecordingSyncService::class.java))
            }
        }

        /** What the service is doing now, for the device scenarios. */
        fun status(context: Context): Map<String, Any?> {
            val service = instance
            val posted = context.getSystemService(NotificationManager::class.java)
                .activeNotifications
                .firstOrNull { it.id == NOTIFICATION_ID }
            val tap = posted?.notification?.contentIntent
            return mapOf(
                "running" to (service != null && service.appliedTypes != 0),
                "types" to namesOf(service?.appliedTypes ?: 0),
                "text" to posted?.notification?.extras?.getCharSequence(Notification.EXTRA_TEXT)?.toString(),
                "notificationPosted" to (posted != null),
                "opensKoe" to (tap != null && tap.isActivity && tap.creatorPackage == context.packageName),
                "wakeLockHeld" to (service?.wakeLock?.isHeld == true),
                "actions" to (posted?.notification?.actions?.map { it.title.toString() } ?: emptyList<String>()),
                // False once the screen is off, as behind the lock screen.
                "screenInteractive" to (context.getSystemService(POWER_SERVICE) as PowerManager).isInteractive,
            )
        }

        /**
         * Sends the notification's 停止 the way a tap does, for the device
         * scenarios. Returns false when the notification has no such action.
         */
        fun pressStop(context: Context): Boolean {
            val action = context.getSystemService(NotificationManager::class.java)
                .activeNotifications
                .firstOrNull { it.id == NOTIFICATION_ID }
                ?.notification
                ?.actions
                ?.firstOrNull { it.title.toString() == STOP_TITLE }
                ?: return false
            action.actionIntent.send()
            return true
        }
    }
}
