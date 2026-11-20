package com.semanticcraft.koe

import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.semanticcraft.koe.core.HostSessionStore
import com.semanticcraft.koe.platform.capture.PermissionRequester
import com.semanticcraft.koe.ui.screens.KoeRootScreen
import com.semanticcraft.koe.ui.theme.KoeTheme

class MainActivity : ComponentActivity() {
    private var activeStore by mutableStateOf<HostSessionStore?>(null)
    private var pendingPermissionCallback: ((Map<String, Boolean>) -> Unit)? = null
    private val permissionLauncher = registerForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions(),
    ) { results ->
        val callback = pendingPermissionCallback
        pendingPermissionCallback = null
        callback?.invoke(results)
    }
    private val permissionRequester: PermissionRequester = { permissions, callback ->
        runOnUiThread {
            if (isFinishing || isDestroyed) {
                callback(emptyMap())
            } else {
                pendingPermissionCallback = callback
                permissionLauncher.launch(permissions)
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        val app = application as KoeApplication
        app.permissionCoordinator.attachActivity(permissionRequester)
        activeStore = app.applyLaunchIntent(intent)
        setContent {
            val store = activeStore
            if (store != null) {
                KoeTheme {
                    KoeRootScreen(store = store)
                }
            }
        }
    }

    override fun onDestroy() {
        (application as KoeApplication).permissionCoordinator.detachActivity(permissionRequester)
        pendingPermissionCallback = null
        super.onDestroy()
    }

    override fun onStart() {
        super.onStart()
        (application as KoeApplication).hostCoordinator.setForegroundActive(true)
    }

    override fun onStop() {
        (application as KoeApplication).hostCoordinator.setForegroundActive(false)
        super.onStop()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        activeStore = (application as KoeApplication).applyLaunchIntent(intent)
    }
}
