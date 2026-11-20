package com.semanticcraft.koe.platform.capture

import android.app.Notification
import android.content.Intent
import org.junit.Assert.assertEquals
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
}
