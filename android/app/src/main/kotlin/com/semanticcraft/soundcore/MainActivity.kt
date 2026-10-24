package com.semanticcraft.soundcore

import android.content.Intent
import android.os.Bundle
import io.flutter.embedding.engine.FlutterEngine
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
            intent.removeExtra(KoePlatformPlugin.EXTRA_MEETING_REMINDER_TITLE)
        }
        super.onCreate(savedInstanceState)
        KoePlatformPlugin.handleMeetingReminderIntent(this, intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        KoePlatformPlugin.handleMeetingReminderIntent(this, intent)
    }

    // Koe's channels live in KoePlatformPlugin, so a service can run Dart
    // without this activity; the engine may already have them.
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        KoeEngine.attach(flutterEngine)
    }

    companion object {
        // quick_actions_android's QuickActions.EXTRA_ACTION.
        private const val QUICK_ACTION_EXTRA = "some unique action key"
    }
}
