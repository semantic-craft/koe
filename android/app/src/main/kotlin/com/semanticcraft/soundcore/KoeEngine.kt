package com.semanticcraft.soundcore

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.IBinder
import android.util.Log
import com.ryanheise.audioservice.AudioService
import com.ryanheise.audioservice.AudioServicePlugin
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache

/**
 * The one Flutter engine Koe runs in, kept running without the activity by
 * whoever needs Dart: the foreground service while it works, and the scan
 * for the recorder while it is near (全天常驻, RecorderScan).
 *
 * audio_service owns the engine. It starts one headless for a service just
 * as for the activity, running Dart's main (AudioServicePlugin.java:70-114),
 * and destroys it once nothing binds its AudioService, which happens when
 * the activity goes (AudioServicePlugin.java:350-366 disconnects,
 * AudioServicePlugin.java:829 disposes). A hold binds AudioService too, so
 * Dart outlives the activity until the last holder lets go. Main thread
 * only.
 */
object KoeEngine {
    private const val TAG = "KoeEngine"
    private val holders = mutableSetOf<String>()
    private var binding: ServiceConnection? = null

    /** The engine, started headless when no activity started it yet. */
    fun get(context: Context): FlutterEngine =
        AudioServicePlugin.getFlutterEngine(context).also(::attach)

    /** Whether the engine runs now, with or without the activity. */
    fun running(): Boolean =
        FlutterEngineCache.getInstance().contains(AudioServicePlugin.getFlutterEngineId())

    /** Adds Koe's own channels, which the generated registrant leaves out. */
    fun attach(engine: FlutterEngine) {
        if (!engine.plugins.has(KoePlatformPlugin::class.java)) {
            engine.plugins.add(KoePlatformPlugin())
        }
    }

    /** Keeps the engine running for [holder], starting it if it does not run. */
    fun hold(context: Context, holder: String) {
        get(context)
        if (!holders.add(holder) || binding != null) return
        val connection = object : ServiceConnection {
            override fun onServiceConnected(name: ComponentName?, service: IBinder?) {}

            override fun onServiceDisconnected(name: ComponentName?) {}

            // AudioService only hands a binder to MediaBrowser; the binding
            // alone keeps it, and with it the engine.
            override fun onNullBinding(name: ComponentName?) {}
        }
        val app = context.applicationContext
        if (!app.bindService(Intent(app, AudioService::class.java), connection, Context.BIND_AUTO_CREATE)) {
            Log.w(TAG, "Could not bind AudioService for $holder")
        }
        binding = connection
    }

    fun release(context: Context, holder: String) {
        if (!holders.remove(holder) || holders.isNotEmpty()) return
        val connection = binding ?: return
        binding = null
        context.applicationContext.unbindService(connection)
    }
}
