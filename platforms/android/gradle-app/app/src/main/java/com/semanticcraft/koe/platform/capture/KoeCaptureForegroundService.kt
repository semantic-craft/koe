package com.semanticcraft.koe.platform.capture

import android.app.ForegroundServiceStartNotAllowedException
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import com.semanticcraft.koe.KoeApplication
import com.semanticcraft.koe.MainActivity
import com.semanticcraft.koe.core.CaptureAction

open class KoeCaptureForegroundService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        ensureChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_PAUSE -> {
                (application as? KoeApplication)?.performNotificationCaptureAction(CaptureAction.PAUSE)
                return START_NOT_STICKY
            }
            ACTION_RESUME -> {
                (application as? KoeApplication)?.performNotificationCaptureAction(CaptureAction.RESUME)
                return START_NOT_STICKY
            }
            ACTION_END -> {
                (application as? KoeApplication)?.performNotificationCaptureAction(CaptureAction.END)
                return START_NOT_STICKY
            }
        }
        val paused = intent?.getBooleanExtra(EXTRA_PAUSED, false) ?: false
        val modeTitle = intent?.getStringExtra(EXTRA_MODE_TITLE)
        val fgsFlags = intent?.getIntExtra(EXTRA_FGS_TYPES, FGS_FLAG_MICROPHONE) ?: FGS_FLAG_MICROPHONE
        val beanCapture = intent?.getBooleanExtra(EXTRA_BEAN_CAPTURE, false) == true
        val notification = buildNotification(paused, modeTitle, fgsFlags, beanCapture)
        startForegroundCompat(notification, fgsFlags)
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        stopForeground(STOP_FOREGROUND_REMOVE)
        notifyForegroundSyncInvalidated()
        super.onDestroy()
    }

    private fun notifyForegroundSyncInvalidated() {
        (application as? KoeApplication ?: applicationContext as? KoeApplication)?.invalidateForegroundServiceSync()
    }

    private fun ensureChannel() {
        val manager = getSystemService(NotificationManager::class.java) ?: return
        val channel = NotificationChannel(
            CHANNEL_ID,
            CHANNEL_NAME,
            NotificationManager.IMPORTANCE_LOW,
        )
        manager.createNotificationChannel(channel)
    }

    private fun buildNotification(paused: Boolean, modeTitle: String?, fgsFlags: Int, beanCapture: Boolean): Notification {
        val openIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val openPending = PendingIntent.getActivity(
            this,
            REQ_OPEN_APP,
            openIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val hasMicrophone = (fgsFlags and FGS_FLAG_MICROPHONE) != 0
        val contentText = when {
            beanCapture -> if (paused) "录音豆已暂停" else "正在用录音豆录音"
            !hasMicrophone -> "正在同步录音豆"
            paused -> "已暂停"
            else -> "正在后台录音"
        }
        val builder = Notification.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_btn_speak_now)
            .setContentTitle(modeTitle?.takeIf { it.isNotBlank() } ?: "Koe 录音")
            .setContentText(contentText)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setContentIntent(openPending)
        if (hasMicrophone || beanCapture) {
            val toggleAction = if (paused) {
                Notification.Action.Builder(
                    null,
                    "继续",
                    servicePendingIntent(ACTION_RESUME, REQ_TOGGLE),
                ).build()
            } else {
                Notification.Action.Builder(
                    null,
                    "暂停",
                    servicePendingIntent(ACTION_PAUSE, REQ_TOGGLE),
                ).build()
            }
            val endAction = Notification.Action.Builder(
                null,
                "结束",
                servicePendingIntent(ACTION_END, REQ_END),
            ).build()
            builder.addAction(toggleAction).addAction(endAction)
        }
        return builder.build()
    }

    private fun servicePendingIntent(action: String, requestCode: Int): PendingIntent {
        val intent = Intent(this, KoeCaptureForegroundService::class.java).setAction(action)
        return PendingIntent.getService(
            this,
            requestCode,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    internal open fun promoteToForeground(notification: Notification, types: Int?) {
        if (types != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            startForeground(NOTIFICATION_ID, notification, types)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun startForegroundCompat(notification: Notification, fgsFlags: Int) {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                var types = 0
                if ((fgsFlags and FGS_FLAG_MICROPHONE) != 0) {
                    types = types or ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
                }
                if ((fgsFlags and FGS_FLAG_CONNECTED_DEVICE) != 0) {
                    types = types or ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE
                }
                if (types == 0) {
                    types = ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
                }
                promoteToForeground(notification, types)
            } else {
                promoteToForeground(notification, null)
            }
        } catch (_: SecurityException) {
            notifyForegroundSyncInvalidated()
            stopSelf()
        } catch (error: RuntimeException) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
                error is ForegroundServiceStartNotAllowedException
            ) {
                notifyForegroundSyncInvalidated()
                stopSelf()
            } else {
                throw error
            }
        }
    }

    companion object {
        const val CHANNEL_ID = "koe_capture"
        const val CHANNEL_NAME = "录音保活"
        const val NOTIFICATION_ID = 4101
        const val ACTION_SYNC = "com.semanticcraft.koe.capture.SYNC"
        const val ACTION_PAUSE = "com.semanticcraft.koe.capture.PAUSE"
        const val ACTION_RESUME = "com.semanticcraft.koe.capture.RESUME"
        const val ACTION_END = "com.semanticcraft.koe.capture.END"
        const val EXTRA_BEAN_CAPTURE = "extra_bean_capture"
        const val EXTRA_PAUSED = "extra_paused"
        const val EXTRA_MODE_TITLE = "extra_mode_title"
        const val EXTRA_FGS_TYPES = "extra_fgs_types"
        const val FGS_FLAG_MICROPHONE = 1 shl 0
        const val FGS_FLAG_CONNECTED_DEVICE = 1 shl 1

        private const val REQ_OPEN_APP = 100
        private const val REQ_TOGGLE = 101
        private const val REQ_END = 102

        fun sync(
            context: Context,
            state: CaptureForegroundState,
            fgsFlags: Int = FGS_FLAG_MICROPHONE,
        ): Boolean {
            val appContext = context.applicationContext
            if (!state.active) {
                val stopIntent = Intent(appContext, KoeCaptureForegroundService::class.java)
                runCatching {
                    appContext.stopService(stopIntent)
                }
                return true
            }
            val intent = Intent(appContext, KoeCaptureForegroundService::class.java).apply {
                action = ACTION_SYNC
                putExtra(EXTRA_BEAN_CAPTURE, state.beanCapture)
                putExtra(EXTRA_PAUSED, state.paused)
                putExtra(EXTRA_MODE_TITLE, state.modeTitle)
                putExtra(EXTRA_FGS_TYPES, fgsFlags)
            }
            return try {
                appContext.startForegroundService(intent)
                true
            } catch (_: SecurityException) {
                false
            } catch (error: RuntimeException) {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
                    error is ForegroundServiceStartNotAllowedException
                ) {
                    false
                } else {
                    throw error
                }
            }
        }
    }
}
