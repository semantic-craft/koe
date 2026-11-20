package com.semanticcraft.koe

import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.semanticcraft.koe.core.HostSessionStore
import com.semanticcraft.koe.ui.screens.KoeRootScreen
import com.semanticcraft.koe.ui.theme.KoeTheme

class MainActivity : ComponentActivity() {
    private var activeStore by mutableStateOf<HostSessionStore?>(null)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        activeStore = (application as KoeApplication).applyLaunchIntent(intent)
        setContent {
            val store = activeStore
            if (store != null) {
                KoeTheme {
                    KoeRootScreen(store = store)
                }
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        activeStore = (application as KoeApplication).applyLaunchIntent(intent)
    }
}
