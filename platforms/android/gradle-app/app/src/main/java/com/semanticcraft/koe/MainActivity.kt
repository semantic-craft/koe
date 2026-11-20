package com.semanticcraft.koe

import android.content.ActivityNotFoundException
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
import com.semanticcraft.koe.platform.files.DocumentPickerHost
import com.semanticcraft.koe.platform.files.PickerLaunchFailure
import com.semanticcraft.koe.platform.files.SystemSafDocumentIo
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
    private val openDocumentLauncher = registerForActivityResult(
        ActivityResultContracts.OpenDocument(),
    ) { uri ->
        (application as KoeApplication).fileActions.onOpenDocumentResult(uri)
    }
    private val createMarkdownLauncher = registerForActivityResult(
        ActivityResultContracts.CreateDocument(SystemSafDocumentIo.MARKDOWN_MIME_TYPE),
    ) { uri ->
        (application as KoeApplication).fileActions.onCreateMarkdownResult(uri)
    }
    private val openDocumentTreeLauncher = registerForActivityResult(
        ActivityResultContracts.OpenDocumentTree(),
    ) { uri ->
        (application as KoeApplication).fileActions.onOpenDocumentTreeResult(uri)
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

    private val documentPickerHost = object : DocumentPickerHost {
        override fun launchOpenDocument(
            mimeTypes: Array<String>,
            onLaunchFailed: (PickerLaunchFailure) -> Unit,
        ) {
            runPickerLaunch(onLaunchFailed) { openDocumentLauncher.launch(mimeTypes) }
        }

        override fun launchCreateMarkdownDocument(
            suggestedFilename: String,
            onLaunchFailed: (PickerLaunchFailure) -> Unit,
        ) {
            runPickerLaunch(onLaunchFailed) { createMarkdownLauncher.launch(suggestedFilename) }
        }

        override fun launchOpenDocumentTree(onLaunchFailed: (PickerLaunchFailure) -> Unit) {
            runPickerLaunch(onLaunchFailed) { openDocumentTreeLauncher.launch(null) }
        }
    }

    private fun runPickerLaunch(
        onLaunchFailed: (PickerLaunchFailure) -> Unit,
        launch: () -> Unit,
    ) {
        runOnUiThread {
            if (isFinishing || isDestroyed) {
                onLaunchFailed(PickerLaunchFailure.ACTIVITY_UNAVAILABLE)
            } else {
                try {
                    launch()
                } catch (_: ActivityNotFoundException) {
                    onLaunchFailed(PickerLaunchFailure.NO_PICKER_APP)
                }
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        val app = application as KoeApplication
        app.permissionCoordinator.attachActivity(permissionRequester)
        app.fileActions.attachActivity(documentPickerHost)
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
        val app = application as KoeApplication
        app.permissionCoordinator.detachActivity(permissionRequester)
        app.fileActions.detachActivity(
            host = documentPickerHost,
            keepPendingRequest = isChangingConfigurations,
        )
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
