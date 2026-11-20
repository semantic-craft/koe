package com.semanticcraft.koe.platform.files

import android.content.ContentProvider
import android.content.ContentValues
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import android.os.Bundle
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import com.semanticcraft.koe.MainActivity
import com.semanticcraft.koe.bridge.KoeNativeBridge
import com.semanticcraft.koe.core.HostBridgeClient
import com.semanticcraft.koe.core.HostJson
import com.semanticcraft.koe.core.HostSessionStore
import com.semanticcraft.koe.core.HostSnapshot
import com.semanticcraft.koe.core.PcmIngestReceipt
import com.semanticcraft.koe.core.PcmIngestStatus
import com.semanticcraft.koe.core.PlaybackProgressReceipt
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.InputStream
import java.io.OutputStream
import java.nio.file.Files
import java.util.concurrent.Executor
import kotlin.math.abs
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowContentResolver

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class AndroidFileActionsLifecycleTest {
    private class ControllablePickerHost(
        var failureToTrigger: PickerLaunchFailure? = null,
    ) : DocumentPickerHost {
        var openLaunchCount = 0
        var createLaunchCount = 0
        var treeLaunchCount = 0

        override fun launchOpenDocument(
            mimeTypes: Array<String>,
            onLaunchFailed: (PickerLaunchFailure) -> Unit,
        ) {
            openLaunchCount += 1
            failureToTrigger?.let(onLaunchFailed)
        }

        override fun launchCreateMarkdownDocument(
            suggestedFilename: String,
            onLaunchFailed: (PickerLaunchFailure) -> Unit,
        ) {
            createLaunchCount += 1
            failureToTrigger?.let(onLaunchFailed)
        }

        override fun launchOpenDocumentTree(onLaunchFailed: (PickerLaunchFailure) -> Unit) {
            treeLaunchCount += 1
            failureToTrigger?.let(onLaunchFailed)
        }
    }

    private class MemorySafIo : SafDocumentIo {
        val displayNames = mutableMapOf<Uri, String?>()
        val mimeTypes = mutableMapOf<Uri, String?>()
        val lastModifiedMs = mutableMapOf<Uri, Long?>()
        val payloads = mutableMapOf<Uri, ByteArray>()
        val outputs = mutableMapOf<Uri, ByteArrayOutputStream>()
        val createdChildren = mutableListOf<Pair<String, Uri>>()
        val deletedUris = mutableListOf<Uri>()

        override fun queryDisplayName(uri: Uri): String? = displayNames[uri]
        override fun queryMimeType(uri: Uri): String? = mimeTypes[uri]
        override fun queryLastModifiedMs(uri: Uri): Long? = lastModifiedMs[uri]
        override fun openInputStream(uri: Uri): InputStream? = payloads[uri]?.let(::ByteArrayInputStream)
        override fun openOutputStream(uri: Uri): OutputStream = outputs.getOrPut(uri) { ByteArrayOutputStream() }
        override fun createChildMarkdownDocument(treeUri: Uri, fileName: String): Uri =
            Uri.parse("$treeUri/$fileName").also { createdChildren.add(fileName to it) }
        override fun deleteDocumentBestEffort(uri: Uri) {
            deletedUris.add(uri)
        }
    }

    private class RecordingBridge : HostBridgeClient {
        private var current = HostSnapshot.empty.copy(generation = 1L)
        val commandTypes = mutableListOf<String>()
        var observedImportName: String? = null
        var observedImportLastModifiedMs: Long? = null
        var observedExportRecordId: String? = null
        var observedExportDate: String? = null
        var observedExportRecordIds: List<String> = emptyList()
        var batchExportFiles: Map<String, String> = emptyMap()

        override fun apiVersion(): Int = 2
        override fun sessionCreate(directory: String): Long = 777L
        override fun sessionCreateWithCredentials(
            directory: String,
            credentialBridge: KoeNativeBridge.CredentialBridge,
            isolated: Boolean,
        ): Long = 777L

        override fun sessionDestroy(handle: Long): Boolean = true
        override fun sessionGeneration(handle: Long): Long = current.generation
        override fun sessionSnapshotJson(handle: Long, nowEpochSec: Long): String =
            HostJson.json.encodeToString(HostSnapshot.serializer(), current)

        override fun sessionDispatchJson(handle: Long, commandJson: String, nowEpochSec: Long): String {
            val obj = HostJson.json.parseToJsonElement(commandJson) as JsonObject
            val type = obj["type"]?.jsonPrimitive?.content.orEmpty()
            commandTypes.add(type)
            when (type) {
                "import_file" -> {
                    val staged = File(obj["path"]?.jsonPrimitive?.content.orEmpty())
                    observedImportName = staged.name
                    observedImportLastModifiedMs = staged.lastModified()
                }
                "export_workspace_markdown" -> {
                    observedExportRecordId = obj["recordId"]?.jsonPrimitive?.content
                    observedExportDate = obj["date"]?.jsonPrimitive?.content
                    File(obj["path"]?.jsonPrimitive?.content.orEmpty()).writeText("# 旋转后导出", Charsets.UTF_8)
                }
                "export_records_markdown" -> {
                    val dir = File(obj["directory"]?.jsonPrimitive?.content.orEmpty())
                    observedExportRecordIds = (obj["recordIds"] as JsonArray).map { it.jsonPrimitive.content }
                    batchExportFiles.forEach { (name, content) -> File(dir, name).writeText(content, Charsets.UTF_8) }
                }
            }
            current = current.copy(generation = current.generation + 1L)
            return sessionSnapshotJson(handle, nowEpochSec)
        }

        override fun sessionIngestBle(handle: Long, bytes: ByteArray, nowEpochSec: Long): Long = current.generation
        override fun sessionIngestPcm(
            handle: Long,
            recordId: String,
            sessionId: String,
            lane: String,
            sequence: Long,
            epoch: Long,
            capturedStartNs: Long?,
            samples: ShortArray,
            sampleCount: Int,
            nowEpochSec: Long,
        ): PcmIngestReceipt = PcmIngestReceipt(current.generation, 0L, PcmIngestStatus.REJECTED)

        override fun sessionReportPlaybackProgress(
            handle: Long,
            recordId: String,
            requestId: Long,
            positionMs: Long,
            isPlaying: Boolean,
            lastProjectedNowSec: Long,
            nowEpochSec: Long,
        ): PlaybackProgressReceipt = PlaybackProgressReceipt(
            current.generation, current.generation, positionMs, nowEpochSec, isPlaying, true, false,
        )

        override fun sessionDrainBleTx(handle: Long): ByteArray = ByteArray(0)
        override fun sessionDrainLocalAsr(handle: Long): ByteArray = ByteArray(0)
        override fun sessionPollTimers(handle: Long, elapsedMs: Long, nowEpochSec: Long): Long = current.generation
    }

    private fun withTempRoots(block: (importRoot: File, exportRoot: File) -> Unit) {
        val base = Files.createTempDirectory("koe-saf-lifecycle-test").toFile()
        try {
            block(File(base, "import"), File(base, "export"))
        } finally {
            base.deleteRecursively()
        }
    }

    @Test
    fun activityRecreationPreservesPendingImportAndExportResults() = withTempRoots { importRoot, exportRoot ->
        val bridge = RecordingBridge()
        val store = HostSessionStore("/tmp/koe-rotate-saf", bridge = bridge)
        val safIo = MemorySafIo()
        val actions = AndroidFileActions(safIo, importRoot, exportRoot, ioExecutor = Executor { it.run() })
        actions.onSessionBound(store)

        val hostBeforeRotate = ControllablePickerHost()
        val hostAfterRotate = ControllablePickerHost()
        actions.attachActivity(hostBeforeRotate)

        actions.requestImportFile()
        assertEquals(1, hostBeforeRotate.openLaunchCount)

        actions.detachActivity(hostBeforeRotate, keepPendingRequest = true)
        actions.attachActivity(hostAfterRotate)

        actions.requestImportFile()
        assertEquals(0, hostAfterRotate.openLaunchCount)

        val importUri = Uri.parse("content://docs/rotated-import")
        safIo.displayNames[importUri] = "旋转后导入.txt"
        safIo.payloads[importUri] = "正文".toByteArray(Charsets.UTF_8)
        actions.onOpenDocumentResult(importUri)

        assertEquals(listOf("import_file"), bridge.commandTypes)
        assertEquals("旋转后导入.txt", bridge.observedImportName)
        assertTrue(importRoot.listFiles().orEmpty().isEmpty())

        actions.requestExportWorkspace("rec-9", null, "旋转导出.md")
        assertEquals(1, hostAfterRotate.createLaunchCount)

        val hostAfterSecondRotate = ControllablePickerHost()
        actions.detachActivity(hostAfterRotate, keepPendingRequest = true)
        actions.attachActivity(hostAfterSecondRotate)

        val exportUri = Uri.parse("content://docs/rotated-export")
        actions.onCreateMarkdownResult(exportUri)

        assertEquals(listOf("import_file", "export_workspace_markdown"), bridge.commandTypes)
        assertEquals("# 旋转后导出", safIo.outputs[exportUri]?.toString(Charsets.UTF_8.name()))
        assertTrue(exportRoot.listFiles().orEmpty().isEmpty())
    }

    @Test
    fun permanentDestroyClearsPendingStateAndStrayCreateResultDeletesOrphan() = withTempRoots { importRoot, exportRoot ->
        val bridge = RecordingBridge()
        val store = HostSessionStore("/tmp/koe-destroy-saf", bridge = bridge)
        val safIo = MemorySafIo()
        val actions = AndroidFileActions(safIo, importRoot, exportRoot, ioExecutor = Executor { it.run() })
        actions.onSessionBound(store)

        val firstHost = ControllablePickerHost()
        val wrongHost = ControllablePickerHost()
        actions.attachActivity(firstHost)
        actions.requestExportWorkspace("rec-1", null, "test.md")
        assertEquals(1, firstHost.createLaunchCount)

        actions.detachActivity(wrongHost, keepPendingRequest = false)
        actions.requestImportFile()
        assertEquals(0, firstHost.openLaunchCount)

        actions.detachActivity(firstHost, keepPendingRequest = false)

        val orphanUri = Uri.parse("content://docs/stray-orphan")
        actions.onCreateMarkdownResult(orphanUri)
        assertTrue(orphanUri in safIo.deletedUris)
        assertTrue(bridge.commandTypes.isEmpty())

        val secondHost = ControllablePickerHost()
        actions.attachActivity(secondHost)
        actions.requestImportFile()
        assertEquals(1, secondHost.openLaunchCount)
    }

    @Test
    fun noPickerAppClearsPendingStateAndReportsNativeError() = withTempRoots { importRoot, exportRoot ->
        val bridge = RecordingBridge()
        val store = HostSessionStore("/tmp/koe-no-picker", bridge = bridge)
        val safIo = MemorySafIo()
        val actions = AndroidFileActions(safIo, importRoot, exportRoot, ioExecutor = Executor { it.run() })
        actions.onSessionBound(store)

        val failingHost = ControllablePickerHost(failureToTrigger = PickerLaunchFailure.NO_PICKER_APP)
        actions.attachActivity(failingHost)

        actions.requestImportFile()
        assertEquals("系统未找到可用的文件选择器。", store.navigation.value.effectiveError)

        failingHost.failureToTrigger = PickerLaunchFailure.ACTIVITY_UNAVAILABLE
        store.clearError()
        actions.requestExportWorkspace("rec-1", null, "demo.md")
        assertNull(store.navigation.value.effectiveError)

        failingHost.failureToTrigger = null
        actions.requestExportRecords(listOf("rec-1"))
        assertEquals(1, failingHost.treeLaunchCount)
    }

    @Test
    fun processDeathRestoresPendingImportExportWorkspaceAndExportRecords() = withTempRoots { importRoot, exportRoot ->
        val inlineExecutor = Executor { it.run() }
        val safIo = MemorySafIo()
        val host1 = ControllablePickerHost()
        val store1 = HostSessionStore("/tmp/koe-death-1", bridge = RecordingBridge())
        val actions1 = AndroidFileActions(safIo, importRoot, exportRoot, ioExecutor = inlineExecutor)
        actions1.onSessionBound(store1)
        actions1.attachActivity(host1)

        actions1.requestImportFile()
        val importBundle = Bundle()
        MainActivity.writePendingPickerState(importBundle, actions1.exportPendingState())
        val importBridge = RecordingBridge()
        val actionsAfterImportDeath = AndroidFileActions(safIo, importRoot, exportRoot, ioExecutor = inlineExecutor)
        actionsAfterImportDeath.onSessionBound(HostSessionStore("/tmp/koe-death-2", bridge = importBridge))
        actionsAfterImportDeath.restorePendingState(MainActivity.readPendingPickerState(importBundle))
        val importUri = Uri.parse("content://docs/death-import")
        safIo.displayNames[importUri] = "重启恢复.md"
        safIo.payloads[importUri] = "# 恢复内容".toByteArray(Charsets.UTF_8)
        actionsAfterImportDeath.onOpenDocumentResult(importUri)
        assertEquals(listOf("import_file"), importBridge.commandTypes)
        assertEquals("重启恢复.md", importBridge.observedImportName)
        assertNull(actionsAfterImportDeath.exportPendingState())
        assertTrue(importRoot.listFiles().orEmpty().isEmpty())

        actions1.onOpenDocumentResult(null)
        actions1.requestExportWorkspace("rec-42", null, "复盘/纪要.md")
        val workspaceBundle = Bundle()
        MainActivity.writePendingPickerState(workspaceBundle, actions1.exportPendingState())
        val workspaceBridge = RecordingBridge()
        val actionsAfterExportDeath = AndroidFileActions(safIo, importRoot, exportRoot, ioExecutor = inlineExecutor)
        actionsAfterExportDeath.onSessionBound(HostSessionStore("/tmp/koe-death-3", bridge = workspaceBridge))
        actionsAfterExportDeath.restorePendingState(MainActivity.readPendingPickerState(workspaceBundle))
        val exportUri = Uri.parse("content://docs/death-export")
        actionsAfterExportDeath.onCreateMarkdownResult(exportUri)
        assertEquals(listOf("export_workspace_markdown"), workspaceBridge.commandTypes)
        assertEquals("rec-42", workspaceBridge.observedExportRecordId)
        assertEquals("# 旋转后导出", safIo.outputs[exportUri]?.toString(Charsets.UTF_8.name()))
        assertFalse(exportUri in safIo.deletedUris)
        assertTrue(exportRoot.listFiles().orEmpty().isEmpty())

        val dateBundle = Bundle()
        MainActivity.writePendingPickerState(
            dateBundle,
            PendingPickerState(PendingPickerState.KIND_EXPORT_WORKSPACE, date = "2026-11-20", safeName = "全天.md"),
        )
        val dateBridge = RecordingBridge()
        val actionsAfterDateDeath = AndroidFileActions(safIo, importRoot, exportRoot, ioExecutor = inlineExecutor)
        actionsAfterDateDeath.onSessionBound(HostSessionStore("/tmp/koe-death-date", bridge = dateBridge))
        actionsAfterDateDeath.restorePendingState(MainActivity.readPendingPickerState(dateBundle))
        val dateExportUri = Uri.parse("content://docs/death-date-export")
        actionsAfterDateDeath.onCreateMarkdownResult(dateExportUri)
        assertEquals("2026-11-20", dateBridge.observedExportDate)
        assertFalse(dateExportUri in safIo.deletedUris)

        actions1.onCreateMarkdownResult(null)
        actions1.requestExportRecords(listOf("rec-1", " rec-2 ", "rec-1"))
        val batchBundle = Bundle()
        MainActivity.writePendingPickerState(batchBundle, actions1.exportPendingState())
        val batchBridge = RecordingBridge().apply {
            batchExportFiles = mapOf("a.md" to "# A", "b.md" to "# B")
        }
        val actionsAfterBatchDeath = AndroidFileActions(safIo, importRoot, exportRoot, ioExecutor = inlineExecutor)
        actionsAfterBatchDeath.onSessionBound(HostSessionStore("/tmp/koe-death-4", bridge = batchBridge))
        actionsAfterBatchDeath.restorePendingState(MainActivity.readPendingPickerState(batchBundle))
        val treeUri = Uri.parse("content://docs/tree/death-batch")
        actionsAfterBatchDeath.onOpenDocumentTreeResult(treeUri)
        assertEquals(listOf("export_records_markdown"), batchBridge.commandTypes)
        assertEquals(listOf("rec-1", "rec-2"), batchBridge.observedExportRecordIds)
        assertEquals(listOf("a.md", "b.md"), safIo.createdChildren.map { it.first })
        assertEquals("# A", safIo.outputs[safIo.createdChildren[0].second]?.toString(Charsets.UTF_8.name()))
        assertEquals("# B", safIo.outputs[safIo.createdChildren[1].second]?.toString(Charsets.UTF_8.name()))
        assertTrue(exportRoot.listFiles().orEmpty().isEmpty())
    }

    @Test
    fun restorePendingStateDoesNotOverwriteLiveRequestAndIgnoresInvalidState() = withTempRoots { importRoot, exportRoot ->
        val bridge = RecordingBridge()
        val store = HostSessionStore("/tmp/koe-restore-guard", bridge = bridge)
        val safIo = MemorySafIo()
        val actions = AndroidFileActions(safIo, importRoot, exportRoot, ioExecutor = Executor { it.run() })

        actions.restorePendingState(PendingPickerState(kind = PendingPickerState.KIND_IMPORT))
        assertNull(actions.exportPendingState())

        actions.onSessionBound(store)
        actions.restorePendingState(PendingPickerState(kind = "unknown"))
        actions.restorePendingState(PendingPickerState(kind = PendingPickerState.KIND_EXPORT_WORKSPACE, recordId = "  "))
        actions.restorePendingState(PendingPickerState(kind = PendingPickerState.KIND_EXPORT_RECORDS, recordIds = listOf("", " ")))
        assertNull(actions.exportPendingState())
        assertNull(MainActivity.readPendingPickerState(Bundle()))

        actions.attachActivity(ControllablePickerHost())
        actions.requestExportWorkspace("rec-live", null, "live.md")
        actions.restorePendingState(PendingPickerState(kind = PendingPickerState.KIND_IMPORT))
        assertEquals(PendingPickerState.KIND_EXPORT_WORKSPACE, actions.exportPendingState()?.kind)

        val exportUri = Uri.parse("content://docs/live-export")
        actions.onCreateMarkdownResult(exportUri)
        assertEquals(listOf("export_workspace_markdown"), bridge.commandTypes)
        assertEquals("rec-live", bridge.observedExportRecordId)
        assertFalse(exportUri in safIo.deletedUris)
    }

    @Test
    fun performImportPreservesSourceLastModifiedTimestampInStagedFile() = withTempRoots { importRoot, exportRoot ->
        val bridge = RecordingBridge()
        val store = HostSessionStore("/tmp/koe-import-mtime", bridge = bridge)
        val safIo = MemorySafIo()
        val actions = AndroidFileActions(safIo, importRoot, exportRoot, ioExecutor = Executor { it.run() })
        actions.onSessionBound(store)
        actions.attachActivity(ControllablePickerHost())

        val historicalMs = 1_700_000_000_000L
        val uri = Uri.parse("content://docs/historical-audio")
        safIo.displayNames[uri] = "历史录音.wav"
        safIo.payloads[uri] = byteArrayOf(1, 2, 3, 4)
        safIo.lastModifiedMs[uri] = historicalMs

        actions.requestImportFile()
        actions.onOpenDocumentResult(uri)

        assertEquals(listOf("import_file"), bridge.commandTypes)
        assertEquals("历史录音.wav", bridge.observedImportName)
        val observedMs = bridge.observedImportLastModifiedMs
        assertNotNull(observedMs)
        assertTrue(
            "expected staged mtime near $historicalMs, got $observedMs",
            abs(observedMs!! - historicalMs) < 2_000L,
        )
    }

    @Test
    fun systemSafDocumentIoQueriesLastModifiedSeparatelyFromDisplayName() {
        val authority = "com.semanticcraft.koe.test.docs"
        val provider = object : ContentProvider() {
            override fun onCreate(): Boolean = true
            override fun query(
                uri: Uri,
                projection: Array<out String>?,
                selection: String?,
                selectionArgs: Array<out String>?,
                sortOrder: String?,
            ): Cursor {
                val col = projection?.singleOrNull()
                if (col == OpenableColumns.DISPLAY_NAME) {
                    return MatrixCursor(arrayOf(OpenableColumns.DISPLAY_NAME)).apply {
                        addRow(arrayOf(uri.lastPathSegment))
                    }
                }
                if (col == DocumentsContract.Document.COLUMN_LAST_MODIFIED) {
                    return when (uri.lastPathSegment) {
                        "dated.wav" -> MatrixCursor(arrayOf(col)).apply { addRow(arrayOf(1_700_000_000_000L)) }
                        "zero.wav" -> MatrixCursor(arrayOf(col)).apply { addRow(arrayOf(0L)) }
                        else -> throw IllegalArgumentException("COLUMN_LAST_MODIFIED unsupported")
                    }
                }
                throw IllegalArgumentException("Unexpected projection: ${projection?.toList()}")
            }
            override fun getType(uri: Uri): String? = null
            override fun insert(uri: Uri, values: ContentValues?): Uri? = null
            override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int = 0
            override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<out String>?): Int = 0
        }
        ShadowContentResolver.registerProviderInternal(authority, provider)
        val io = SystemSafDocumentIo(RuntimeEnvironment.getApplication())
        val datedUri = Uri.parse("content://$authority/dated.wav")
        val zeroUri = Uri.parse("content://$authority/zero.wav")
        val brokenUri = Uri.parse("content://$authority/notes.md")

        assertEquals("dated.wav", io.queryDisplayName(datedUri))
        assertEquals(1_700_000_000_000L, io.queryLastModifiedMs(datedUri))
        assertNull(io.queryLastModifiedMs(zeroUri))
        assertEquals("notes.md", io.queryDisplayName(brokenUri))
        assertNull(io.queryLastModifiedMs(brokenUri))
    }
}
