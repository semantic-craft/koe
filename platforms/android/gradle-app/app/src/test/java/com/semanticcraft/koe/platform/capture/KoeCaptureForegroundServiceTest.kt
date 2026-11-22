package com.semanticcraft.koe.platform.capture

import android.Manifest
import android.app.Notification
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import androidx.test.core.app.ApplicationProvider
import com.semanticcraft.koe.KoeApplication
import com.semanticcraft.koe.core.ActiveCaptureSnapshot
import com.semanticcraft.koe.core.CaptureMode
import com.semanticcraft.koe.core.HostSnapshot
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class KoeCaptureForegroundServiceTest {
    @Test
    fun bleOnlyForegroundNotificationUsesSyncCopyWithoutMicrophoneActions() {
        val service = Robolectric.buildService(KoeCaptureForegroundService::class.java).create().get()
        val intent = Intent(service, KoeCaptureForegroundService::class.java).apply {
            action = KoeCaptureForegroundService.ACTION_SYNC
            putExtra(KoeCaptureForegroundService.EXTRA_PAUSED, false)
            putExtra(KoeCaptureForegroundService.EXTRA_MODE_TITLE, "Soundcore Work")
            putExtra(
                KoeCaptureForegroundService.EXTRA_FGS_TYPES,
                KoeCaptureForegroundService.FGS_FLAG_CONNECTED_DEVICE,
            )
        }

        service.onStartCommand(intent, 0, 1)

        val notification = Shadows.shadowOf(service).lastForegroundNotification
        assertNotNull(notification)
        assertEquals(
            "正在同步录音豆",
            notification.extras.getCharSequence(Notification.EXTRA_TEXT)?.toString(),
        )
        assertTrue(notification.actions.isNullOrEmpty())
    }

    @Test
    fun beanRecordingAndPausePublishControlsForTheSameSession() {
        val service = Robolectric.buildService(KoeCaptureForegroundService::class.java).create().get()
        val app = ApplicationProvider.getApplicationContext<KoeApplication>()
        val shadowApp = Shadows.shadowOf(app)
        shadowApp.grantPermissions(Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT)
        val snapshot = HostSnapshot.empty.copy(
            capture = HostSnapshot.empty.capture.copy(activeSource = "bean"),
            device = HostSnapshot.empty.device.copy(connected = true, recording = true),
        )
        for (paused in listOf(false, true)) {
            val phase = if (paused) "paused" else "recording"
            app.bleCoordinator.onSnapshotChanged(snapshot.copy(
                activeCapture = ActiveCaptureSnapshot(CaptureMode.MEETING, phase, "Soundcore Work"),
            ))
            val intent = checkNotNull(shadowApp.nextStartedService)
            service.onStartCommand(intent, 0, 1)
            val notification = Shadows.shadowOf(service).lastForegroundNotification
            assertEquals(if (paused) "录音豆已暂停" else "正在用录音豆录音",
                notification.extras.getCharSequence(Notification.EXTRA_TEXT))
            assertEquals(listOf(if (paused) "继续" else "暂停", "结束"), notification.actions.map { it.title })
        }
    }

    @Test
    fun microphoneForegroundNotificationKeepsRecordingCopyAndControls() {
        val service = Robolectric.buildService(KoeCaptureForegroundService::class.java).create().get()
        val intent = Intent(service, KoeCaptureForegroundService::class.java).apply {
            action = KoeCaptureForegroundService.ACTION_SYNC
            putExtra(KoeCaptureForegroundService.EXTRA_PAUSED, true)
            putExtra(KoeCaptureForegroundService.EXTRA_MODE_TITLE, "实时纪要")
            putExtra(
                KoeCaptureForegroundService.EXTRA_FGS_TYPES,
                KoeCaptureForegroundService.FGS_FLAG_MICROPHONE or
                    KoeCaptureForegroundService.FGS_FLAG_CONNECTED_DEVICE,
            )
        }

        service.onStartCommand(intent, 0, 1)

        val notification = Shadows.shadowOf(service).lastForegroundNotification
        assertNotNull(notification)
        assertEquals(
            "已暂停",
            notification.extras.getCharSequence(Notification.EXTRA_TEXT)?.toString(),
        )
        val titles = notification.actions?.map { it.title.toString() }.orEmpty()
        assertEquals(listOf("继续", "结束"), titles)
    }

    @Test
    fun failedForegroundServiceStartDoesNotSuppressRetryForSameTarget() {
        var failNext = true
        var startAttempts = 0
        val app = object : KoeApplication() {
            init {
                attachBaseContext(ApplicationProvider.getApplicationContext())
            }

            override fun getApplicationContext(): Context = this

            override fun startForegroundService(service: Intent?): ComponentName? {
                startAttempts += 1
                if (failNext) {
                    throw SecurityException("simulated FGS start blocked")
                }
                return super.startForegroundService(service)
            }
        }
        val activeState = CaptureForegroundState(active = true, paused = false, modeTitle = "实时纪要")

        assertFalse(KoeCaptureForegroundService.sync(app, activeState, KoeCaptureForegroundService.FGS_FLAG_MICROPHONE))
        assertEquals(1, startAttempts)

        app.updateCaptureForegroundState(activeState)
        assertEquals(2, startAttempts)

        failNext = false
        app.setForegroundActive(true)
        assertEquals(3, startAttempts)

        app.updateCaptureForegroundState(activeState)
        assertEquals(3, startAttempts)
        assertTrue(KoeCaptureForegroundService.sync(app, CaptureForegroundState(active = false, paused = false, modeTitle = null)))
    }

    @Test
    fun asyncStartForegroundFailureAndServiceDestroyInvalidateSyncCacheForRetry() {
        val app = ApplicationProvider.getApplicationContext<KoeApplication>()
        val shadowApp = Shadows.shadowOf(app)
        val activeState = CaptureForegroundState(active = true, paused = false, modeTitle = "实时纪要")

        app.updateCaptureForegroundState(activeState)
        val firstIntent = checkNotNull(shadowApp.nextStartedService)
        app.updateCaptureForegroundState(activeState)
        assertEquals(null, shadowApp.nextStartedService)

        val failingService = Robolectric.buildService(SecurityFailingForegroundService::class.java).create().get()
        failingService.onStartCommand(firstIntent, 0, 1)
        assertTrue(Shadows.shadowOf(failingService).isStoppedBySelf)

        app.updateCaptureForegroundState(activeState)
        val retriedAfterFailure = shadowApp.nextStartedService
        assertNotNull(retriedAfterFailure)

        val normalService = Robolectric.buildService(KoeCaptureForegroundService::class.java).create().get()
        normalService.onStartCommand(retriedAfterFailure, 0, 2)
        normalService.onDestroy()

        app.updateCaptureForegroundState(activeState)
        assertNotNull(shadowApp.nextStartedService)
    }

    class SecurityFailingForegroundService : KoeCaptureForegroundService() {
        override fun promoteToForeground(notification: Notification, types: Int?) {
            throw SecurityException("simulated Android 14+ FGS type rejection")
        }
    }
}
