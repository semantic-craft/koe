package com.semanticcraft.koe

import android.app.Application
import android.content.Intent
import com.semanticcraft.koe.core.AndroidCredentials
import com.semanticcraft.koe.core.CaptureAction
import com.semanticcraft.koe.core.HostAdapterEvent
import com.semanticcraft.koe.core.HostBridgeActions
import com.semanticcraft.koe.core.HostSessionStore
import com.semanticcraft.koe.core.JniHostBridgeClient
import com.semanticcraft.koe.platform.AndroidHostCoordinator
import com.semanticcraft.koe.platform.capture.AndroidAudioInputMonitor
import com.semanticcraft.koe.platform.capture.AndroidAudioRecordSource
import com.semanticcraft.koe.platform.capture.AndroidCaptureCoordinator
import com.semanticcraft.koe.platform.capture.AndroidPermissionCoordinator
import com.semanticcraft.koe.platform.capture.KoeCaptureForegroundService
import com.semanticcraft.koe.platform.capture.SystemAudioFocusController
import com.semanticcraft.koe.platform.playback.AndroidAudioTrackSink
import com.semanticcraft.koe.platform.playback.AndroidPlaybackCoordinator
import java.io.File
import java.nio.charset.StandardCharsets

class KoeApplication : Application() {
    private val sessionLock = Any()
    private var currentStore: HostSessionStore? = null
    val hostCoordinator = AndroidHostCoordinator()
    val permissionCoordinator: AndroidPermissionCoordinator by lazy {
        AndroidPermissionCoordinator(this)
    }
    val audioInputMonitor: AndroidAudioInputMonitor by lazy {
        AndroidAudioInputMonitor(this)
    }
    val captureCoordinator: AndroidCaptureCoordinator by lazy {
        AndroidCaptureCoordinator(
            source = AndroidAudioRecordSource(this, permissionCoordinator),
            focusController = SystemAudioFocusController(this),
            onForegroundStateChanged = { state ->
                KoeCaptureForegroundService.sync(this, state)
            },
        )
    }
    val playbackCoordinator: AndroidPlaybackCoordinator by lazy {
        AndroidPlaybackCoordinator(
            sinkFactory = AndroidAudioTrackSink.Factory,
            focusController = SystemAudioFocusController(this),
        )
    }

    override fun onCreate() {
        super.onCreate()
        hostCoordinator.registerAdapter(audioInputMonitor)
        hostCoordinator.registerAdapter(captureCoordinator)
        hostCoordinator.registerAdapter(playbackCoordinator)
    }

    fun setForegroundActive(active: Boolean) {
        hostCoordinator.setForegroundActive(active)
    }

    fun performNotificationCaptureAction(action: CaptureAction) {
        val store = synchronized(sessionLock) { currentStore } ?: return
        store.performCaptureAction(action)
    }

    fun applyLaunchIntent(intent: Intent?): HostSessionStore {
        val debugWorkspace = if (BuildConfig.DEBUG) {
            intent?.getStringExtra(EXTRA_WORKSPACE)
        } else {
            null
        }
        val debugFixture = if (BuildConfig.DEBUG) {
            intent?.getStringExtra(EXTRA_SNAPSHOT_FIXTURE)
        } else {
            null
        }

        val workspaceDir = resolveSafeWorkspaceDir(filesDir, debugWorkspace)
        val traceFile = File(filesDir, TRACE_FILE_NAME)

        var newlyCreated = false
        val store = synchronized(sessionLock) {
            val existing = currentStore
            if (existing != null && existing.workspacePath == workspaceDir.absolutePath) {
                existing
            } else {
                existing?.shutdown()
                workspaceDir.mkdirs()
                val credentials = if (BuildConfig.DEBUG) {
                    AndroidCredentials.forIsolated()
                } else {
                    AndroidCredentials.forKeystore(File(filesDir, CREDENTIALS_DIR_NAME))
                }
                val created = HostSessionStore(
                    workspacePath = workspaceDir.absolutePath,
                    bridge = JniHostBridgeClient(),
                    credentials = credentials,
                    isolatedCredentials = BuildConfig.DEBUG,
                    allowDebugFixture = BuildConfig.DEBUG,
                    autoOpen = false,
                )
                created.onTraceUpdated = {
                    created.writeTraceAtomically(traceFile)
                }
                created.openSession()
                created.send(
                    HostAdapterEvent.SyncAppMetadata(
                        version = BuildConfig.VERSION_NAME,
                        build = BuildConfig.VERSION_CODE.toString(),
                        platform = "android",
                        hostDisplayName = "Android",
                        supportsSystemAudio = false,
                        supportsSelfUpdate = BuildConfig.ALLOW_SELF_UPDATE,
                        nativeSpeechLabel = "Android 本机",
                    ),
                )
                currentStore = created
                newlyCreated = true
                created
            }
        }

        if (newlyCreated) {
            hostCoordinator.bind(
                store,
                HostBridgeActions(
                    resumeMicrophone = { captureCoordinator.resume() },
                ),
            )
        }

        if (BuildConfig.DEBUG && !debugFixture.isNullOrBlank()) {
            val fixtureFile = resolveSafeFixtureFile(filesDir, debugFixture)
            if (fixtureFile == null) {
                store.reportNativeError("无法读取调试快照文件。")
            } else {
                val loaded = try {
                    val json = fixtureFile.readText(StandardCharsets.UTF_8)
                    store.loadDebugSnapshotFixtureJson(json)
                } catch (_: Exception) {
                    false
                }
                if (!loaded) {
                    store.reportNativeError("无法读取调试快照文件。")
                }
            }
        }

        store.writeTraceAtomically(traceFile)
        return store
    }

    override fun onTerminate() {
        hostCoordinator.shutdown()
        synchronized(sessionLock) {
            currentStore?.shutdown()
            currentStore = null
        }
        super.onTerminate()
    }

    companion object {
        const val EXTRA_WORKSPACE = "koe_workspace"
        const val EXTRA_SNAPSHOT_FIXTURE = "koe_snapshot_fixture"
        const val DEFAULT_WORKSPACE_DIR = "KoeWorkspace"
        const val CREDENTIALS_DIR_NAME = "koe-credentials"
        const val TRACE_FILE_NAME = "koe-trace.json"

        internal fun resolveSafeWorkspaceDir(baseDir: File, rawSubpath: String?): File {
            val fallback = File(baseDir, DEFAULT_WORKSPACE_DIR)
            val cleaned = rawSubpath?.trim().orEmpty()
            if (cleaned.isEmpty()) return fallback
            return resolveStrictChild(baseDir, cleaned) ?: fallback
        }

        internal fun resolveSafeFixtureFile(baseDir: File, rawPath: String?): File? {
            val cleaned = rawPath?.trim().orEmpty()
            if (cleaned.isEmpty()) return null
            val candidate = resolveStrictChild(baseDir, cleaned) ?: return null
            return if (candidate.isFile && candidate.canRead()) candidate else null
        }

        private fun resolveStrictChild(baseDir: File, relativePath: String): File? {
            if (relativePath.contains('\u0000')) return null
            if (relativePath.startsWith("/") || relativePath.startsWith("\\")) return null
            val segments = relativePath.split('/', '\\')
            if (segments.any { it.isEmpty() || it == "." || it == ".." }) return null
            val canonicalBase = baseDir.canonicalFile
            val candidate = File(canonicalBase, relativePath).canonicalFile
            val basePrefix = canonicalBase.path.trimEnd(File.separatorChar) + File.separatorChar
            if (!candidate.path.startsWith(basePrefix)) return null
            return candidate
        }
    }
}
