package com.semanticcraft.soundcore

import android.companion.CompanionDeviceService
import android.companion.DevicePresenceEvent
import android.util.Log

/**
 * Bound by Android while the associated recorder is near (全天常驻), which
 * starts Koe's process when it is not running. While bound it holds the
 * engine, so Dart runs and brings the recorder back; Android unbinds it a
 * few seconds after the recorder is gone, and rebinds it if Koe's process
 * dies while the recorder is still near.
 *
 * Presence is the binding itself, not the events: a connected recorder
 * stops advertising, so Android reports it gone over BLE while the link is
 * up (omi's BleCompanionService.kt:64-71), and keeps the service bound
 * through the connection. Events are logged for diagnosis only.
 */
class KoeCompanionService : CompanionDeviceService() {
    override fun onCreate() {
        super.onCreate()
        KoeEngine.hold(this, HOLDER)
        RecorderCompanion.setPresent(true)
    }

    override fun onDestroy() {
        RecorderCompanion.setPresent(false)
        KoeEngine.release(this, HOLDER)
        super.onDestroy()
    }

    // Android 16+; earlier versions only call the deprecated callbacks.
    override fun onDevicePresenceEvent(event: DevicePresenceEvent) {
        Log.i(TAG, "Presence event ${event.event} for association ${event.associationId}")
    }

    companion object {
        private const val TAG = "KoeCompanion"
        private const val HOLDER = "companion"
    }
}
