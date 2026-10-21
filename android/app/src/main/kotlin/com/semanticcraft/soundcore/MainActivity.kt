package com.semanticcraft.soundcore

import android.app.AlertDialog
import android.content.Intent
import android.provider.Settings
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import com.ryanheise.audioservice.AudioServiceActivity

class MainActivity : AudioServiceActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.anker.anker_recorder/background_sync",
        ).setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "update" -> result.success(
                        RecordingSyncService.update(
                            applicationContext,
                            call.argument<List<String>>("types") ?: emptyList(),
                            call.argument<String>("text"),
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
    }

    private fun explainNotificationsOff() {
        if (isFinishing || isDestroyed) return
        AlertDialog.Builder(this)
            .setTitle("通知已关闭")
            .setMessage(
                "取回录音时，Koe 会在通知栏显示「Koe 正在同步录音」，点它就能回到 Koe。" +
                    "通知关闭后同步照常进行，只是看不到这条通知。",
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
