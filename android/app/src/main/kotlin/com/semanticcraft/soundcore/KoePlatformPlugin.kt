package com.semanticcraft.soundcore

import android.Manifest
import android.app.Activity
import android.app.AlertDialog
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry

/**
 * Koe's own platform channels: the foreground service, the recorder's
 * Wi-Fi hotspot, 全天常驻 and whether the phone is on Wi-Fi. A plugin
 * rather than code in MainActivity, so they are there whenever the engine
 * runs, with the activity or headless after a service started Dart
 * (KoeEngine). What needs the activity (a permission prompt, a dialog, the
 * association dialog) goes through it while one is attached and gives up
 * quietly without one.
 */
class KoePlatformPlugin :
    FlutterPlugin,
    ActivityAware,
    PluginRegistry.RequestPermissionsResultListener,
    PluginRegistry.ActivityResultListener {
    private lateinit var appContext: Context
    private lateinit var backgroundSync: MethodChannel
    private lateinit var softAp: MethodChannel
    private lateinit var presence: MethodChannel
    private lateinit var wifi: MethodChannel
    private val mainThread = Handler(Looper.getMainLooper())
    private var activityBinding: ActivityPluginBinding? = null
    private var pendingLocalNetwork: MethodChannel.Result? = null

    private val activity: Activity?
        get() = activityBinding?.activity

    // 停止 on the notification: Dart saves the take or the text and ends the
    // work. If Dart cannot answer, the service just stops.
    private val stopListener: () -> Unit = {
        mainThread.post {
            backgroundSync.invokeMethod(
                "stopRequested",
                null,
                object : MethodChannel.Result {
                    override fun success(result: Any?) {}

                    override fun error(code: String, message: String?, details: Any?) {
                        RecordingSyncService.stop(appContext)
                    }

                    override fun notImplemented() {
                        RecordingSyncService.stop(appContext)
                    }
                },
            )
        }
    }

    // Android would not run the service as these types (microphone while
    // Koe is behind the lock screen), or took dataSync away at its daily
    // limit: Dart stops that work and says why.
    private val refusedListener: (List<String>) -> Unit = { types ->
        mainThread.post { backgroundSync.invokeMethod("refused", types) }
    }

    private val presenceListener: (Boolean) -> Unit = { present ->
        mainThread.post { presence.invokeMethod("presence", present) }
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        val messenger = binding.binaryMessenger
        backgroundSync = MethodChannel(messenger, "com.anker.anker_recorder/background_sync")
        backgroundSync.setMethodCallHandler(::onBackgroundSync)
        softAp = MethodChannel(messenger, "com.semanticcraft.koe/softap_network")
        softAp.setMethodCallHandler(::onSoftAp)
        presence = MethodChannel(messenger, "com.semanticcraft.koe/recorder_presence")
        presence.setMethodCallHandler(::onPresence)
        wifi = MethodChannel(messenger, "com.semanticcraft.koe/wifi_connectivity")
        wifi.setMethodCallHandler(::onWifi)
        RecordingSyncService.stopListener = stopListener
        RecordingSyncService.refusedListener = refusedListener
        RecorderCompanion.presenceListener = presenceListener
    }

    // The engine is going: nothing is left to record or to answer 停止.
    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        backgroundSync.setMethodCallHandler(null)
        softAp.setMethodCallHandler(null)
        presence.setMethodCallHandler(null)
        wifi.setMethodCallHandler(null)
        if (RecordingSyncService.stopListener === stopListener) RecordingSyncService.stopListener = null
        if (RecordingSyncService.refusedListener === refusedListener) RecordingSyncService.refusedListener = null
        if (RecorderCompanion.presenceListener === presenceListener) RecorderCompanion.presenceListener = null
        RecordingSyncService.stop(appContext)
        SoftApNetwork.shared(appContext).release()
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activityBinding = binding
        binding.addRequestPermissionsResultListener(this)
        binding.addActivityResultListener(this)
    }

    override fun onDetachedFromActivityForConfigChanges() = onDetachedFromActivity()

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) =
        onAttachedToActivity(binding)

    override fun onDetachedFromActivity() {
        activityBinding?.removeRequestPermissionsResultListener(this)
        activityBinding?.removeActivityResultListener(this)
        activityBinding = null
        pendingLocalNetwork?.success(false)
        pendingLocalNetwork = null
    }

    private fun onBackgroundSync(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "update" -> result.success(
                    RecordingSyncService.update(
                        appContext,
                        call.argument<List<String>>("types") ?: emptyList(),
                        call.argument<String>("text"),
                        call.argument<Boolean>("stoppable") ?: false,
                        call.argument<Boolean>("wakeLock") ?: true,
                    ),
                )
                "stop" -> {
                    RecordingSyncService.stop(appContext)
                    result.success(null)
                }
                "status" -> result.success(RecordingSyncService.status(appContext))
                "explainNotificationsOff" -> {
                    explainNotificationsOff()
                    result.success(null)
                }
                // Device scenarios leave the screen the way the Home gesture
                // does, then check the work keeps running.
                "moveTaskToBack" -> result.success(activity?.moveTaskToBack(true) ?: false)
                "pressStop" -> result.success(RecordingSyncService.pressStop(appContext))
                else -> result.notImplemented()
            }
        } catch (error: Exception) {
            result.error(
                "background_sync_error",
                error.message ?: "Background sync service failed",
                null,
            )
        }
    }

    // Wi-Fi export: joining the recorder's hotspot and reaching it there
    // (SoftApNetwork).
    private fun onSoftAp(call: MethodCall, result: MethodChannel.Result) {
        val network = SoftApNetwork.shared(appContext)
        when (call.method) {
            "ensureLocalNetwork" -> ensureLocalNetwork(result)
            "join" -> network.join(
                call.argument<String>("ssid")!!,
                call.argument<String>("password")!!,
                call.argument<Int>("timeoutMs")!!,
            ) { error -> result.success(error) }
            "openTunnel" -> network.openTunnel(
                call.argument<String>("host")!!,
                call.argument<Int>("port")!!,
            ) { port, error ->
                if (port != null) {
                    result.success(port)
                } else {
                    result.error("tunnel_failed", error, null)
                }
            }
            "startKeepalive" -> {
                network.startKeepalive(call.argument<String>("host")!!)
                result.success(null)
            }
            "release" -> {
                network.release()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    // 全天常驻 (RecorderCompanion).
    private fun onPresence(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "state" -> result.success(
                mapOf(
                    "supported" to RecorderCompanion.supported(appContext),
                    "address" to RecorderCompanion.address(appContext),
                    "present" to RecorderCompanion.present,
                ),
            )
            "associate" -> {
                val current = activity
                if (current == null) {
                    result.success(false)
                } else {
                    RecorderCompanion.associate(current, call.argument<String>("address")!!) { ok ->
                        result.success(ok)
                    }
                }
            }
            "observe" -> {
                RecorderCompanion.observe(appContext, call.argument<Boolean>("on") ?: false)
                result.success(null)
            }
            "disassociate" -> {
                RecorderCompanion.disassociate(appContext)
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    // Whether the default network is unmetered Wi-Fi alone, for downloads
    // Koe keeps off mobile data and phone hotspots
    // (lib/platform/wifi_connectivity.dart).
    private fun onWifi(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "isWifiConnected") return result.notImplemented()
        val manager = appContext.getSystemService(ConnectivityManager::class.java)
        val caps = manager.getNetworkCapabilities(manager.activeNetwork)
        result.success(
            caps != null &&
                caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) &&
                !caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) &&
                !caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) &&
                caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
                caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED),
        )
    }

    /**
     * Android 17 blocks LAN traffic for apps targeting it until they hold
     * ACCESS_LOCAL_NETWORK. It sits in the Nearby devices group that Koe's
     * Bluetooth permissions already opened, so this normally returns true
     * without showing anything.
     */
    private fun ensureLocalNetwork(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.CINNAMON_BUN ||
            appContext.checkSelfPermission(Manifest.permission.ACCESS_LOCAL_NETWORK) ==
            PackageManager.PERMISSION_GRANTED
        ) {
            result.success(true)
            return
        }
        val current = activity ?: return result.success(false)
        pendingLocalNetwork?.success(false)
        pendingLocalNetwork = result
        current.requestPermissions(arrayOf(Manifest.permission.ACCESS_LOCAL_NETWORK), LOCAL_NETWORK_REQUEST)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ): Boolean {
        if (requestCode != LOCAL_NETWORK_REQUEST) return false
        pendingLocalNetwork?.success(
            grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED,
        )
        pendingLocalNetwork = null
        return true
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != RecorderCompanion.CHOOSER_REQUEST) return false
        RecorderCompanion.onChooserResult(appContext, resultCode)
        return true
    }

    private fun explainNotificationsOff() {
        val current = activity ?: return
        if (current.isFinishing || current.isDestroyed) return
        AlertDialog.Builder(current)
            .setTitle("通知已关闭")
            .setMessage(
                "取回录音、手机录音或监听时，Koe 会在通知栏显示正在做什么，点它就能回到 Koe，" +
                    "录音和监听还能从通知上停止。通知关闭后这些工作照常进行，只是看不到这条通知。",
            )
            .setNegativeButton("暂不", null)
            .setPositiveButton("去设置") { _, _ ->
                current.startActivity(
                    Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                        .putExtra(Settings.EXTRA_APP_PACKAGE, current.packageName),
                )
            }
            .show()
    }

    companion object {
        // Clear of permission_handler's request code (24).
        private const val LOCAL_NETWORK_REQUEST = 3205
    }
}
