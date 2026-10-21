package com.semanticcraft.soundcore

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
                    "start" -> {
                        RecordingSyncService.start(applicationContext)
                        result.success(null)
                    }
                    "stop" -> {
                        RecordingSyncService.stop(applicationContext)
                        result.success(null)
                    }
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
}
