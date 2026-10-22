package com.semanticcraft.soundcore

import android.Manifest
import android.app.AlertDialog
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import com.ryanheise.audioservice.AudioServiceActivity

class MainActivity : AudioServiceActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        // 开始录音 from the launcher acts once. Android hands its intent back
        // when it recreates this activity or reopens Koe from recents, so the
        // shortcut is dropped there before quick_actions reads it.
        if (savedInstanceState != null ||
            (intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY) != 0
        ) {
            intent.removeExtra(QUICK_ACTION_EXTRA)
        }
        super.onCreate(savedInstanceState)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val backgroundSync = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.anker.anker_recorder/background_sync",
        )
        // Kept out of the lambdas below, which can outlive this activity.
        val appContext = applicationContext
        val mainThread = Handler(Looper.getMainLooper())
        // 停止 on the notification: Dart saves the take or the text and ends
        // the work. If Dart cannot answer, the service just stops.
        RecordingSyncService.stopListener = {
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
        // Koe is behind the lock screen): Dart stops that work and says why.
        RecordingSyncService.refusedListener = { types ->
            mainThread.post { backgroundSync.invokeMethod("refused", types) }
        }
        // audio_service caches the engine past this activity, so Dart (and a
        // take) can outlive it. When the engine itself goes, nothing is left
        // to record or to answer 停止: stop the service with it.
        if (watchedEngine !== flutterEngine) {
            watchedEngine = flutterEngine
            flutterEngine.addEngineLifecycleListener(object : FlutterEngine.EngineLifecycleListener {
                override fun onPreEngineRestart() {}

                override fun onEngineWillDestroy() {
                    RecordingSyncService.stopListener = null
                    RecordingSyncService.refusedListener = null
                    RecordingSyncService.stop(appContext)
                    SoftApNetwork.shared(appContext).release()
                    if (watchedEngine === flutterEngine) watchedEngine = null
                }
            })
        }
        backgroundSync.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "update" -> result.success(
                        RecordingSyncService.update(
                            applicationContext,
                            call.argument<List<String>>("types") ?: emptyList(),
                            call.argument<String>("text"),
                            call.argument<Boolean>("stoppable") ?: false,
                        ),
                    )
                    "stop" -> {
                        RecordingSyncService.stop(applicationContext)
                        result.success(null)
                    }
                    "status" -> result.success(RecordingSyncService.status(applicationContext))
                    "explainNotificationsOff" -> {
                        explainNotificationsOff()
                        result.success(null)
                    }
                    // Device scenarios leave the screen the way the Home
                    // gesture does, then check the work keeps running.
                    "moveTaskToBack" -> result.success(moveTaskToBack(true))
                    "pressStop" -> result.success(RecordingSyncService.pressStop(applicationContext))
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
        configureSoftApNetwork(flutterEngine)
    }

    // Wi-Fi export: joining the recorder's hotspot and reaching it there
    // (SoftApNetwork). The permission prompt needs this activity.
    private fun configureSoftApNetwork(flutterEngine: FlutterEngine) {
        val softAp = SoftApNetwork.shared(applicationContext)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.semanticcraft.koe/softap_network",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "ensureLocalNetwork" -> ensureLocalNetwork(result)
                "join" -> softAp.join(
                    call.argument<String>("ssid")!!,
                    call.argument<String>("password")!!,
                    call.argument<Int>("timeoutMs")!!,
                ) { error -> result.success(error) }
                "openTunnel" -> softAp.openTunnel(
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
                    softAp.startKeepalive(call.argument<String>("host")!!)
                    result.success(null)
                }
                "release" -> {
                    softAp.release()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    /**
     * Android 17 blocks LAN traffic for apps targeting it until they hold
     * ACCESS_LOCAL_NETWORK. It sits in the Nearby devices group that Koe's
     * Bluetooth permissions already opened, so this normally returns true
     * without showing anything.
     */
    private fun ensureLocalNetwork(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.CINNAMON_BUN ||
            checkSelfPermission(Manifest.permission.ACCESS_LOCAL_NETWORK) ==
            PackageManager.PERMISSION_GRANTED
        ) {
            result.success(true)
            return
        }
        pendingLocalNetwork?.success(false)
        pendingLocalNetwork = result
        requestPermissions(arrayOf(Manifest.permission.ACCESS_LOCAL_NETWORK), LOCAL_NETWORK_REQUEST)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != LOCAL_NETWORK_REQUEST) return
        pendingLocalNetwork?.success(
            grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED,
        )
        pendingLocalNetwork = null
    }

    private var pendingLocalNetwork: MethodChannel.Result? = null

    companion object {
        private var watchedEngine: FlutterEngine? = null

        // quick_actions_android's QuickActions.EXTRA_ACTION.
        private const val QUICK_ACTION_EXTRA = "some unique action key"

        // Clear of permission_handler's request code (24).
        private const val LOCAL_NETWORK_REQUEST = 3205
    }

    private fun explainNotificationsOff() {
        if (isFinishing || isDestroyed) return
        AlertDialog.Builder(this)
            .setTitle("通知已关闭")
            .setMessage(
                "取回录音、手机录音或监听时，Koe 会在通知栏显示正在做什么，点它就能回到 Koe，" +
                    "录音和监听还能从通知上停止。通知关闭后这些工作照常进行，只是看不到这条通知。",
            )
            .setNegativeButton("暂不", null)
            .setPositiveButton("去设置") { _, _ ->
                startActivity(
                    Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                        .putExtra(Settings.EXTRA_APP_PACKAGE, packageName),
                )
            }
            .show()
    }
}
