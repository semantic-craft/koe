package com.semanticcraft.soundcore

import android.app.Activity
import android.bluetooth.le.ScanFilter
import android.companion.AssociationInfo
import android.companion.AssociationRequest
import android.companion.BluetoothDeviceFilter
import android.companion.BluetoothLeDeviceFilter
import android.companion.CompanionDeviceManager
import android.content.Context
import android.content.IntentSender
import android.content.pm.PackageManager
import android.util.Log
import java.util.Locale

/**
 * 全天常驻: Koe associated with the recorder through Android's companion
 * device manager, which lets Koe start its foreground service from the
 * background. Koe watches for the recorder with its own scan
 * ([RecorderScan]): Android's presence watch matches the Bluetooth address
 * the recorder had when Koe associated it, and that address changes.
 *
 * Pattern from omi's OmiCompanionManager.kt:38-136 (associate, chooser).
 * Main thread only.
 */
object RecorderCompanion {
    private const val TAG = "KoeCompanion"

    // Clear of permission_handler's (24) and the local-network request (3205).
    const val CHOOSER_REQUEST = 3206

    private var pending: ((Boolean) -> Unit)? = null

    fun supported(context: Context): Boolean =
        context.packageManager.hasSystemFeature(PackageManager.FEATURE_COMPANION_DEVICE_SETUP)

    private fun manager(context: Context): CompanionDeviceManager? =
        if (supported(context)) context.getSystemService(CompanionDeviceManager::class.java) else null

    private fun association(context: Context): AssociationInfo? =
        manager(context)?.myAssociations?.firstOrNull()

    fun associated(context: Context): Boolean = association(context) != null

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

    /** Drops every association Koe holds. */
    fun disassociate(context: Context) {
        val manager = manager(context) ?: return
        for (association in manager.myAssociations) {
            try {
                manager.disassociate(association.id)
            } catch (error: Exception) {
                Log.w(TAG, "Disassociating ${association.id} failed", error)
            }
        }
    }
}
