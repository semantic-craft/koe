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
import com.semanticcraft.koe.platform.ble.AndroidBleCoordinator
import com.semanticcraft.koe.platform.ble.BleForegroundActivity
import com.semanticcraft.koe.platform.ble.SharedPreferencesBleAddressStore
import com.semanticcraft.koe.platform.ble.SystemAndroidBleTransport
import com.semanticcraft.koe.platform.capture.AndroidAudioInputMonitor
import com.semanticcraft.koe.platform.capture.AndroidAudioRecordSource
import com.semanticcraft.koe.platform.capture.AndroidCaptureCoordinator
import com.semanticcraft.koe.platform.capture.AndroidPermissionCoordinator
import com.semanticcraft.koe.platform.capture.CaptureForegroundState
import com.semanticcraft.koe.platform.capture.KoeCaptureForegroundService
import com.semanticcraft.koe.platform.capture.SystemAudioFocusController
import com.semanticcraft.koe.platform.files.AndroidFileActions
import com.semanticcraft.koe.platform.playback.AndroidAudioTrackSink
import com.semanticcraft.koe.platform.playback.AndroidPlaybackCoordinator
import java.io.File
import java.nio.charset.StandardCharsets
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

open class KoeApplication : Application() {
    private val sessionLock = Any()
    private val foregroundLock = Any()
    private var currentStore: HostSessionStore? = null
    private var captureForegroundState = CaptureForegroundState(active = false, paused = false, modeTitle = null)
    private val traceWriter = Executors.newSingleThreadExecutor()
    private val commandExecutor = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "koe-host-session").apply { isDaemon = true }
    }
    private val captureExecutor = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "koe-capture-work").apply { isDaemon = true }
    }
    private var bleForegroundActivity = BleForegroundActivity.IDLE
    private var lastSyncedForeground: Pair<CaptureForegroundState, Int>? = null
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
                updateCaptureForegroundState(state)
            },
            workExecutor = captureExecutor,
        )
    }
    val playbackCoordinator: AndroidPlaybackCoordinator by lazy {
        AndroidPlaybackCoordinator(
            sinkFactory = AndroidAudioTrackSink.Factory,
            focusController = SystemAudioFocusController(this),
        )
    }
    val bleCoordinator: AndroidBleCoordinator by lazy {
        AndroidBleCoordinator(
            transport = SystemAndroidBleTransport(this, permissionCoordinator::hasBlePermissions),
            addressStore = SharedPreferencesBleAddressStore(this),
            requestBlePermission = permissionCoordinator::requestBlePermissions,
            onForegroundRequirementChanged = { required ->
                updateBleForegroundRequirement(required)
            },
        )
    }
    val fileActions: AndroidFileActions by lazy {
        AndroidFileActions(this)
    }

    override fun onCreate() {
        super.onCreate()
        hostCoordinator.registerAdapter(audioInputMonitor)
        hostCoordinator.registerAdapter(captureCoordinator)
        hostCoordinator.registerAdapter(playbackCoordinator)
        hostCoordinator.registerAdapter(bleCoordinator)
        hostCoordinator.registerAdapter(fileActions)
    }

    internal fun updateCaptureForegroundState(state: CaptureForegroundState) {
        synchronized(foregroundLock) {
            captureForegroundState = state
            syncForegroundServiceLocked()
        }
    }

    private fun updateBleForegroundRequirement(required: BleForegroundActivity) {
        synchronized(foregroundLock) {
            bleForegroundActivity = required
            syncForegroundServiceLocked()
        }
    }

    private fun syncForegroundServiceLocked() {
        val captureState = captureForegroundState
        val bleActivity = bleForegroundActivity
        val effectiveBle = bleActivity != BleForegroundActivity.IDLE && permissionCoordinator.hasBlePermissions()
        var fgsFlags = 0
        if (captureState.active) {
            fgsFlags = fgsFlags or KoeCaptureForegroundService.FGS_FLAG_MICROPHONE
        }
        if (effectiveBle) {
            fgsFlags = fgsFlags or KoeCaptureForegroundService.FGS_FLAG_CONNECTED_DEVICE
        }
        val combinedState = when {
            captureState.active -> captureState
            effectiveBle -> CaptureForegroundState(
                active = true,
                paused = bleActivity == BleForegroundActivity.PAUSED,
                modeTitle = "Soundcore Work",
                beanCapture = bleActivity == BleForegroundActivity.RECORDING || bleActivity == BleForegroundActivity.PAUSED,
            )
            else -> CaptureForegroundState(active = false, paused = false, modeTitle = null)
        }
        val target = combinedState to fgsFlags
        if (lastSyncedForeground == target) return
        lastSyncedForeground = if (KoeCaptureForegroundService.sync(this, combinedState, fgsFlags)) {
            target
        } else {
            null
        }
    }

    internal fun invalidateForegroundServiceSync() {
        synchronized(foregroundLock) {
            if (lastSyncedForeground?.first?.active == true) {
                lastSyncedForeground = null
            }
        }
    }

    fun setForegroundActive(active: Boolean) {
        hostCoordinator.setForegroundActive(active)
        if (active) {
            synchronized(foregroundLock) {
                if (captureForegroundState.active || bleForegroundActivity != BleForegroundActivity.IDLE) {
                    syncForegroundServiceLocked()
                }
            }
        }
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
        val explicitPath = intent?.getStringExtra(EXTRA_TRACE_PATH)
        val traceFile = when {
            explicitPath != null -> resolveStrictChild(File(filesDir, "traces"), explicitPath)
                ?.takeIf { it.extension == "json" }
            BuildConfig.DEBUG -> File(filesDir, TRACE_FILE_NAME)
            else -> null
        }

        var newlyCreated = false
        val store = synchronized(sessionLock) {
            val existing = currentStore
            if (existing != null && existing.workspacePath == workspaceDir.absolutePath) {
                existing
            } else {
                existing?.onTraceUpdated = null
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
                    verificationTrace = BuildConfig.DEBUG && debugWorkspace != null,
                    commandExecutor = commandExecutor,
                )
                created.openSession()
                created.sendEventSync(
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

        store.onTraceUpdated = traceFile?.let { target ->
            val pending = AtomicBoolean(false)
            val enqueue: () -> Unit = {
                if (pending.compareAndSet(false, true)) {
                    traceWriter.execute {
                        pending.set(false)
                        store.writeTraceAtomically(target)
                    }
                }
            }
            enqueue
        }

        if (newlyCreated) {
            hostCoordinator.bind(
                store,
                HostBridgeActions(
                    requestBleScan = { bleCoordinator.requestScan() },
                    flushBleOutbound = { bleCoordinator.flushOutboundFrames() },
                    resumeMicrophone = { captureCoordinator.resume() },
                    requestImportFile = { fileActions.requestImportFile() },
                    requestExportWorkspace = fileActions::requestExportWorkspace,
                    requestExportRecords = { recordIds -> fileActions.requestExportRecords(recordIds) },
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
                    store.loadDebugSnapshotFixtureJson(json, resumeLiveOnCommand =
                        intent?.getBooleanExtra("koe_fixture_to_live", false) == true)
                } catch (_: Exception) {
                    false
                }
                if (!loaded) {
                    store.reportNativeError("无法读取调试快照文件。")
                }
            }
        }

        store.onTraceUpdated?.invoke()
        return store
    }

    override fun onTerminate() {
        hostCoordinator.shutdown()
        captureExecutor.shutdown()
        commandExecutor.shutdown()
        synchronized(sessionLock) {
            currentStore?.onTraceUpdated = null
            currentStore?.shutdown()
            currentStore = null
        }
        traceWriter.shutdown()
        super.onTerminate()
    }

    companion object {
        const val EXTRA_TRACE_PATH = "koe_trace_path"
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
