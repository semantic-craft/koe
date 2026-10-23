package com.semanticcraft.soundcore

import android.app.Activity
import android.bluetooth.le.ScanFilter
import android.companion.AssociationInfo
import android.companion.AssociationRequest
import android.companion.BluetoothDeviceFilter
import android.companion.BluetoothLeDeviceFilter
import android.companion.CompanionDeviceManager
import android.companion.ObservingDevicePresenceRequest
import android.content.Context
import android.content.IntentSender
import android.content.pm.PackageManager
import android.os.Build
import android.util.Log
import java.util.Locale

/**
 * 全天常驻: Koe associated with the recorder through Android's companion
 * device manager. While associated, Android lets Koe start its foreground
 * service from the background. While Koe also observes the recorder's
 * presence, Android binds [KoeCompanionService] whenever the recorder is
 * near, starting Koe if it is not running.
 *
 * Pattern from omi's OmiCompanionManager.kt:38-136 (associate, chooser) and
 * :170-225 (observing by association id on Android 16+, by address before).
 * Main thread only.
 */
object RecorderCompanion {
    private const val TAG = "KoeCompanion"

    // Clear of permission_handler's (24) and the local-network request (3205).
    const val CHOOSER_REQUEST = 3206

    /** Whether the recorder is near: Android has [KoeCompanionService] bound. */
    var present = false
        private set

    /** Tells Dart when [present] changes; set while Flutter runs. */
    var presenceListener: ((Boolean) -> Unit)? = null

    private var pending: ((Boolean) -> Unit)? = null

    fun setPresent(value: Boolean) {
        if (present == value) return
        present = value
        presenceListener?.invoke(value)
    }

    fun supported(context: Context): Boolean =
        context.packageManager.hasSystemFeature(PackageManager.FEATURE_COMPANION_DEVICE_SETUP)

    private fun manager(context: Context): CompanionDeviceManager? =
        if (supported(context)) context.getSystemService(CompanionDeviceManager::class.java) else null

    private fun association(context: Context): AssociationInfo? =
        manager(context)?.myAssociations?.firstOrNull()

    fun associated(context: Context): Boolean = association(context) != null

    /** The associated recorder's address, upper case like Bluetooth's. */
    fun address(context: Context): String? =
        association(context)?.deviceMacAddress?.toString()?.uppercase(Locale.ROOT)

    /**
     * Asks to associate the recorder at [address]. Android shows its own
     * confirmation; [done] gets whether the user allowed it.
     *
     * The classic filter matters: a connected recorder stops advertising, so
     * a scan would not find it, but Android first looks among the devices
     * connected over GATT for a single-device request by address.
     */
    fun associate(activity: Activity, address: String, done: (Boolean) -> Unit) {
        val manager = manager(activity) ?: return done(false)
        finish(false)
        pending = done
        disassociate(activity)
        val mac = address.uppercase(Locale.ROOT)
        val request = AssociationRequest.Builder()
            .addDeviceFilter(BluetoothDeviceFilter.Builder().setAddress(mac).build())
            .addDeviceFilter(
                BluetoothLeDeviceFilter.Builder()
                    .setScanFilter(ScanFilter.Builder().setDeviceAddress(mac).build())
                    .build(),
            )
            .setSingleDevice(true)
            .build()
        manager.associate(
            request,
            activity.mainExecutor,
            object : CompanionDeviceManager.Callback() {
                override fun onAssociationPending(intentSender: IntentSender) {
                    try {
                        activity.startIntentSenderForResult(intentSender, CHOOSER_REQUEST, null, 0, 0, 0)
                    } catch (error: Exception) {
                        Log.w(TAG, "Could not show the association dialog", error)
                        finish(false)
                    }
                }

                override fun onAssociationCreated(associationInfo: AssociationInfo) {
                    finish(true)
                }

                override fun onFailure(error: CharSequence?) {
                    Log.w(TAG, "Association failed: $error")
                    finish(false)
                }
            },
        )
    }

    /** The association dialog closed; a cancel never reaches the callback. */
    fun onChooserResult(context: Context, resultCode: Int) {
        finish(resultCode == Activity.RESULT_OK && associated(context))
    }

    private fun finish(ok: Boolean) {
        val done = pending ?: return
        pending = null
        done(ok)
    }

    /** Starts or stops watching for the associated recorder. */
    @Suppress("DEPRECATION") // By address before Android 16.
    fun observe(context: Context, on: Boolean) {
        val manager = manager(context) ?: return
        for (association in manager.myAssociations) {
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.BAKLAVA) {
                    val request = ObservingDevicePresenceRequest.Builder()
                        .setAssociationId(association.id)
                        .build()
                    if (on) {
                        manager.startObservingDevicePresence(request)
                    } else {
                        manager.stopObservingDevicePresence(request)
                    }
                } else {
                    val mac = association.deviceMacAddress?.toString() ?: continue
                    if (on) {
                        manager.startObservingDevicePresence(mac)
                    } else {
                        manager.stopObservingDevicePresence(mac)
                    }
                }
            } catch (error: Exception) {
                Log.w(TAG, "Observing presence (on=$on) failed", error)
            }
        }
    }

    /** Stops watching and drops every association Koe holds. */
    fun disassociate(context: Context) {
        val manager = manager(context) ?: return
        observe(context, false)
        for (association in manager.myAssociations) {
            try {
                manager.disassociate(association.id)
            } catch (error: Exception) {
                Log.w(TAG, "Disassociating ${association.id} failed", error)
            }
        }
        setPresent(false)
    }
}
