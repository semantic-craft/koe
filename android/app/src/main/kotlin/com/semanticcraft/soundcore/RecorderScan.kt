package com.semanticcraft.soundcore

import android.app.PendingIntent
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.bluetooth.le.BluetoothLeScanner
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.util.Log

/**
 * 全天常驻: a Bluetooth scan Android runs for Koe. It says when the bound
 * recorder comes near, at which Bluetooth address, and when it goes, and
 * starts Koe to say so when Koe does not run.
 *
 * The recorder advertises from an address that changes, at least with
 * every Wi‑Fi export, so the scan matches the classic address its
 * manufacturer data carries: the company id holds the first two bytes and
 * the data starts with the other four (PROTOCOL.md, "Manufacturer data";
 * lib/ble/advertisement.dart). The filter is the one FBP builds for msd
 * (FlutterBluePlusPlugin.java:596-603, byte layout :1935-1946), and the
 * settings are those Android's companion device manager watches devices
 * with (BleDeviceProcessor.java:300-302). The Bluetooth controller matches
 * the filter, so the scan goes on with the screen off and after Koe's
 * process is gone, until the phone restarts, Koe is updated or Bluetooth
 * goes off. Koe starts it again after the first two, and after the third
 * while Koe runs; otherwise when Koe next starts.
 *
 * Android reports each address once when it first sees it and once when it
 * loses it, ten seconds after the last advertisement it caught. A connected
 * recorder stops advertising, so the scan loses it while the link is up.
 * Main thread only.
 */
object RecorderScan {
    private const val TAG = "KoeScan"
    private const val PREFS = "recorder_scan"
    private const val MAC = "mac"
    private const val WATCHING = "watching"
    private const val HOLDER = "nearby"

    /** Tells Dart when the recorder comes near, at which address, or goes; set while Flutter runs. */
    var listener: ((Boolean, String?) -> Unit)? = null

    /** The Bluetooth address the scan last saw the recorder at. */
    var address: String? = null
        private set

    /** Whether the scan sees the recorder now. */
    val present: Boolean
        get() = seen.isNotEmpty()

    // The addresses the scan sees the recorder at now.
    private val seen = mutableSetOf<String>()

    // The scan runs: this process started it, or it reported here.
    private var running = false

    private var bluetoothReceiver: BroadcastReceiver? = null

    /** The classic address Koe watches for, kept across restarts. */
    fun mac(context: Context): String? = prefs(context).getString(MAC, null)

    /**
     * Starts or stops watching for the recorder with the classic address
     * [mac]. Stopping keeps the address, so a recorder bound later with
     * another one is told apart.
     */
    fun observe(context: Context, on: Boolean, mac: String?) {
        val prefs = prefs(context)
        if (!on) {
            prefs.edit().putBoolean(WATCHING, false).apply()
            stop(context)
            return
        }
        if (mac == null) return
        if (running && prefs.getBoolean(WATCHING, false) && prefs.getString(MAC, null) == mac) return
        prefs.edit().putString(MAC, mac).putBoolean(WATCHING, true).apply()
        start(context, mac)
    }

    /** Stops watching and forgets the recorder. */
    fun forget(context: Context) {
        prefs(context).edit().clear().apply()
        stop(context)
    }

    /** Starts the scan again if Koe watches for a recorder: the phone restarted or Koe was updated. */
    fun restore(context: Context) {
        val prefs = prefs(context)
        val mac = prefs.getString(MAC, null) ?: return
        if (prefs.getBoolean(WATCHING, false)) start(context, mac)
    }

    /** What the scan reported, through [RecorderScanReceiver]. */
    fun onResult(context: Context, intent: Intent) {
        val error = intent.getIntExtra(BluetoothLeScanner.EXTRA_ERROR_CODE, 0)
        if (error != 0) {
            Log.w(TAG, "The scan failed: $error")
            running = false
            return
        }
        if (!prefs(context).getBoolean(WATCHING, false)) return
        running = true
        watchBluetooth(context)
        val results = intent.getParcelableArrayListExtra(
            BluetoothLeScanner.EXTRA_LIST_SCAN_RESULT,
            ScanResult::class.java,
        ) ?: return
        val type = intent.getIntExtra(BluetoothLeScanner.EXTRA_CALLBACK_TYPE, 0)
        val wasPresent = present
        val wasAt = address
        for (result in results) {
            val at = result.device.address
            when (type) {
                ScanSettings.CALLBACK_TYPE_FIRST_MATCH -> {
                    seen.add(at)
                    address = at
                }
                ScanSettings.CALLBACK_TYPE_MATCH_LOST -> seen.remove(at)
            }
        }
        changed(context, wasPresent, wasAt)
    }

    private fun start(context: Context, mac: String) {
        lose(context)
        running = false
        // Also when Bluetooth is off now: the scan starts once it is on.
        watchBluetooth(context)
        val filter = filter(mac)
        if (filter == null) {
            Log.w(TAG, "Not a classic address: $mac")
            return
        }
        val scanner = scanner(context) ?: return
        val settings = ScanSettings.Builder()
            .setCallbackType(ScanSettings.CALLBACK_TYPE_FIRST_MATCH or ScanSettings.CALLBACK_TYPE_MATCH_LOST)
            .setScanMode(ScanSettings.SCAN_MODE_LOW_POWER)
            .build()
        try {
            // Android keeps one scan per PendingIntent and ignores a second start.
            scanner.stopScan(pendingIntent(context))
            val error = scanner.startScan(listOf(filter), settings, pendingIntent(context))
            if (error != 0) {
                Log.w(TAG, "Could not start the scan: $error")
                return
            }
            running = true
        } catch (error: Exception) {
            // Bluetooth went off meanwhile, or the scan permission is gone.
            Log.w(TAG, "Could not start the scan", error)
        }
    }

    private fun stop(context: Context) {
        lose(context)
        running = false
        try {
            scanner(context)?.stopScan(pendingIntent(context))
        } catch (error: Exception) {
            Log.w(TAG, "Could not stop the scan", error)
        }
    }

    // A new or stopped scan has seen nothing yet.
    private fun lose(context: Context) {
        val wasPresent = present
        seen.clear()
        changed(context, wasPresent, address)
    }

    private fun changed(context: Context, wasPresent: Boolean, wasAt: String?) {
        if (present && !wasPresent) KoeEngine.hold(context, HOLDER)
        if (present == wasPresent && address == wasAt) return
        listener?.invoke(present, address)
        if (!present && wasPresent) KoeEngine.release(context, HOLDER)
    }

    /**
     * Bluetooth going off ends the scan without a word, so Koe drops what
     * it saw and starts the scan again once Bluetooth is back. Only while
     * Koe runs: Android tells no receiver Koe declares.
     */
    private fun watchBluetooth(context: Context) {
        if (bluetoothReceiver != null) return
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                when (intent.getIntExtra(BluetoothAdapter.EXTRA_STATE, BluetoothAdapter.ERROR)) {
                    BluetoothAdapter.STATE_TURNING_OFF, BluetoothAdapter.STATE_OFF -> {
                        lose(context)
                        running = false
                    }
                    BluetoothAdapter.STATE_ON -> restore(context)
                }
            }
        }
        context.applicationContext.registerReceiver(
            receiver,
            IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED),
            Context.RECEIVER_NOT_EXPORTED,
        )
        bluetoothReceiver = receiver
    }

    private fun scanner(context: Context): BluetoothLeScanner? =
        context.getSystemService(BluetoothManager::class.java)?.adapter?.bluetoothLeScanner

    // The data starts with the classic address's last four bytes; the
    // company id holds the first two.
    private fun filter(mac: String): ScanFilter? {
        val bytes = mac.split(':').map { it.toIntOrNull(16) ?: return null }
        if (bytes.size != 6) return null
        return ScanFilter.Builder()
            .setManufacturerData(
                bytes[0] or (bytes[1] shl 8),
                ByteArray(4) { bytes[it + 2].toByte() },
            )
            .build()
    }

    // Mutable: Android adds the results to it.
    private fun pendingIntent(context: Context): PendingIntent =
        PendingIntent.getBroadcast(
            context,
            0,
            Intent(context, RecorderScanReceiver::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE,
        )

    private fun prefs(context: Context) = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
}

/** Receives what [RecorderScan] reported, and starts it again after a restart or an update. */
class RecorderScanReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        // The receiver's own context cannot bind services or register receivers.
        val app = context.applicationContext
        when (intent.action) {
            Intent.ACTION_BOOT_COMPLETED, Intent.ACTION_MY_PACKAGE_REPLACED -> RecorderScan.restore(app)
            else -> RecorderScan.onResult(app, intent)
        }
    }
}
