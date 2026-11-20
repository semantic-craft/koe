package com.semanticcraft.koe.platform.files

import android.net.Uri
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
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.nio.file.Files
import java.util.concurrent.Executor
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class AndroidFileActionsTest {
    private class FakePickerHost(
        private val actionsProvider: () -> AndroidFileActions,
        var deferred: Boolean = false,
    ) : DocumentPickerHost {
        var openResult: Uri? = null
        var createResult: Uri? = null
        var treeResult: Uri? = null

        var openLaunchCount = 0
        var createLaunchCount = 0
        var treeLaunchCount = 0
        var lastMimeTypes: List<String> = emptyList()
        var lastSuggestedFilename: String? = null

        override fun launchOpenDocument(
            mimeTypes: Array<String>,
            onLaunchFailed: (PickerLaunchFailure) -> Unit,
        ) {
            openLaunchCount += 1
            lastMimeTypes = mimeTypes.toList()
            if (!deferred) {
                actionsProvider().onOpenDocumentResult(openResult)
            }
        }

        override fun launchCreateMarkdownDocument(
            suggestedFilename: String,
            onLaunchFailed: (PickerLaunchFailure) -> Unit,
        ) {
            createLaunchCount += 1
            lastSuggestedFilename = suggestedFilename
            if (!deferred) {
                actionsProvider().onCreateMarkdownResult(createResult)
            }
        }

        override fun launchOpenDocumentTree(onLaunchFailed: (PickerLaunchFailure) -> Unit) {
            treeLaunchCount += 1
            if (!deferred) {
                actionsProvider().onOpenDocumentTreeResult(treeResult)
            }
        }
    }

    private class FakeSafIo : SafDocumentIo {
        val displayNames = mutableMapOf<Uri, String?>()
        val mimeTypes = mutableMapOf<Uri, String?>()
        val inputStreams = mutableMapOf<Uri, () -> InputStream?>()
        val outputBuffers = mutableMapOf<Uri, ByteArrayOutputStream>()
        val outputProviders = mutableMapOf<Uri, () -> OutputStream?>()
        val createdChildren = mutableListOf<Pair<String, Uri>>()
        val deletedUris = mutableListOf<Uri>()
        var childCreator: ((Uri, String) -> Uri?)? = null

        override fun queryDisplayName(uri: Uri): String? = displayNames[uri]
        override fun queryMimeType(uri: Uri): String? = mimeTypes[uri]
        override fun openInputStream(uri: Uri): InputStream? = inputStreams[uri]?.invoke()

        override fun openOutputStream(uri: Uri): OutputStream? {
            outputProviders[uri]?.let { return it() }
            return outputBuffers.getOrPut(uri) { ByteArrayOutputStream() }
        }

        override fun createChildMarkdownDocument(treeUri: Uri, fileName: String): Uri? {
            val custom = childCreator
            val uri = if (custom != null) custom(treeUri, fileName) else Uri.parse("$treeUri/child/$fileName")
            if (uri != null) {
                createdChildren.add(fileName to uri)
            }
            return uri
        }

        override fun deleteDocumentBestEffort(uri: Uri) {
            deletedUris.add(uri)
        }
    }

    private class FileActionBridgeClient : HostBridgeClient {
        private var current = HostSnapshot.empty.copy(generation = 1L)
        val commands = mutableListOf<JsonObject>()
        var observedImportFileName: String? = null
        var observedImportBytes: ByteArray? = null
        var exportWorkspacePayload: String? = "# 导出纪要\n内容"
        var exportWorkspaceError: String? = null
        var exportBatchFiles: Map<String, String> = emptyMap()

        override fun apiVersion(): Int = 2
        override fun sessionCreate(directory: String): Long = 901L
        override fun sessionCreateWithCredentials(
            directory: String,
            credentialBridge: KoeNativeBridge.CredentialBridge,
            isolated: Boolean,
        ): Long = 901L

        override fun sessionDestroy(handle: Long): Boolean = true
        override fun sessionGeneration(handle: Long): Long = current.generation
        override fun sessionSnapshotJson(handle: Long, nowEpochSec: Long): String =
            HostJson.json.encodeToString(HostSnapshot.serializer(), current)

        override fun sessionDispatchJson(handle: Long, commandJson: String, nowEpochSec: Long): String {
            val obj = HostJson.json.parseToJsonElement(commandJson) as JsonObject
            commands.add(obj)
            val type = obj["type"]?.jsonPrimitive?.content
            when (type) {
                "import_file" -> {
                    val path = obj["path"]?.jsonPrimitive?.content.orEmpty()
                    val staged = File(path)
                    if (staged.isFile) {
                        observedImportFileName = staged.name
                        observedImportBytes = staged.readBytes()
                    }
                    current = current.copy(generation = current.generation + 1L, error = null)
                }
                "export_workspace_markdown" -> {
                    val path = obj["path"]?.jsonPrimitive?.content.orEmpty()
                    val payload = exportWorkspacePayload
                    if (payload != null) {
                        File(path).writeText(payload, Charsets.UTF_8)
                        current = current.copy(generation = current.generation + 1L, error = null)
                    } else {
                        current = current.copy(
                            generation = current.generation + 1L,
                            error = exportWorkspaceError ?: "记录不存在",
                        )
                    }
                }
                "export_records_markdown" -> {
                    val dir = File(obj["directory"]?.jsonPrimitive?.content.orEmpty())
                    exportBatchFiles.forEach { (name, content) ->
                        File(dir, name).writeText(content, Charsets.UTF_8)
                    }
                    current = current.copy(generation = current.generation + 1L, error = null)
                }
                else -> current = current.copy(generation = current.generation + 1L)
            }
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
        val base = Files.createTempDirectory("koe-file-actions-test").toFile()
        try {
            block(File(base, "import"), File(base, "export"))
        } finally {
            base.deleteRecursively()
        }
    }

    @Test
    fun importFileStagesPreservesNameDispatchesAndDeletesStagingDir() = withTempRoots { importRoot, exportRoot ->
        val bridge = FileActionBridgeClient()
        val store = HostSessionStore("/tmp/koe-import-ok", bridge = bridge)
        val safIo = FakeSafIo()
        val uri = Uri.parse("content://com.example.docs/document/1")
        val payload = "# 产品评审\n关键决议".toByteArray(Charsets.UTF_8)
        safIo.displayNames[uri] = "产品评审.md"
        safIo.mimeTypes[uri] = "text/markdown"
        safIo.inputStreams[uri] = { ByteArrayInputStream(payload) }

        val actions = AndroidFileActions(safIo, importRoot, exportRoot, ioExecutor = Executor { it.run() })
        val picker = FakePickerHost({ actions }).apply { openResult = uri }
        actions.onSessionBound(store)
        actions.attachActivity(picker)

        actions.requestImportFile()

        assertEquals(listOf("*/*"), picker.lastMimeTypes)
        assertEquals(1, bridge.commands.size)
        assertEquals("import_file", bridge.commands.single()["type"]?.jsonPrimitive?.content)
        assertEquals("产品评审.md", bridge.observedImportFileName)
        assertArrayEquals(payload, bridge.observedImportBytes)
        assertNull(store.navigation.value.effectiveError)
        assertTrue("staging directory must be empty after import", importRoot.listFiles().orEmpty().isEmpty())
    }

    @Test
    fun importFileReportsValidationLimitAndReadErrorsWithZeroLeftovers() = withTempRoots { importRoot, exportRoot ->
        val bridge = FileActionBridgeClient()
        val store = HostSessionStore("/tmp/koe-import-err", bridge = bridge)
        val safIo = FakeSafIo()
        val actions = AndroidFileActions(
            safIo = safIo,
            importStagingRoot = importRoot,
            exportStagingRoot = exportRoot,
            ioExecutor = Executor { it.run() },
            maxImportBytes = 32L,
        )
        val picker = FakePickerHost({ actions })
        actions.onSessionBound(store)
        actions.attachActivity(picker)

        val badPathUri = Uri.parse("content://docs/bad")
        safIo.displayNames[badPathUri] = "../evil.wav"
        picker.openResult = badPathUri
        actions.requestImportFile()
        assertEquals("文件名无效，无法导入。", store.navigation.value.effectiveError)

        val unsupportedUri = Uri.parse("content://docs/mp3")
        safIo.displayNames[unsupportedUri] = "song.mp3"
        safIo.mimeTypes[unsupportedUri] = "audio/mpeg"
        picker.openResult = unsupportedUri
        actions.requestImportFile()
        assertEquals("支持 WAV、TXT、Markdown 和 Koe 资料包", store.navigation.value.effectiveError)

        val hugeUri = Uri.parse("content://docs/huge")
        safIo.displayNames[hugeUri] = "big.wav"
        safIo.inputStreams[hugeUri] = { ByteArrayInputStream(ByteArray(64)) }
        picker.openResult = hugeUri
        actions.requestImportFile()
        assertEquals("请选择不超过 256 MB 的文件", store.navigation.value.effectiveError)

        val secErrUri = Uri.parse("content://docs/denied")
        safIo.displayNames[secErrUri] = "notes.txt"
        safIo.inputStreams[secErrUri] = { throw SecurityException("permission revoked") }
        picker.openResult = secErrUri
        actions.requestImportFile()
        assertEquals("无法读取所选文件。", store.navigation.value.effectiveError)

        assertTrue(bridge.commands.isEmpty())
        assertTrue(importRoot.listFiles().orEmpty().isEmpty())
    }

    @Test
    fun exportWorkspaceWritesSanitizedDocumentAndCleansOrphanOnRustOrWriteError() = withTempRoots { importRoot, exportRoot ->
        val bridge = FileActionBridgeClient()
        val store = HostSessionStore("/tmp/koe-export-single", bridge = bridge)
        val safIo = FakeSafIo()
        val actions = AndroidFileActions(safIo, importRoot, exportRoot, ioExecutor = Executor { it.run() })
        val picker = FakePickerHost({ actions })
        actions.onSessionBound(store)
        actions.attachActivity(picker)

        actions.requestExportWorkspace(null, "   ", "ignored.md")
        assertEquals(0, picker.createLaunchCount)

        val targetUri = Uri.parse("content://docs/out/1")
        picker.createResult = targetUri
        actions.requestExportWorkspace("rec-1", null, "Q4/复盘:纪要.md")

        assertEquals("Q4-复盘-纪要.md", picker.lastSuggestedFilename)
        val cmd = bridge.commands.last()
        assertEquals("export_workspace_markdown", cmd["type"]?.jsonPrimitive?.content)
        assertEquals("rec-1", cmd["recordId"]?.jsonPrimitive?.content)
        assertEquals(true, cmd["includeAnalysis"]?.jsonPrimitive?.boolean)
        assertEquals(true, cmd["includeSources"]?.jsonPrimitive?.boolean)
        assertEquals("# 导出纪要\n内容", safIo.outputBuffers[targetUri]?.toString(Charsets.UTF_8.name()))
        assertTrue(exportRoot.listFiles().orEmpty().isEmpty())

        val rejectedUri = Uri.parse("content://docs/out/rejected")
        bridge.exportWorkspacePayload = null
        bridge.exportWorkspaceError = "记录不存在"
        picker.createResult = rejectedUri
        actions.requestExportWorkspace(null, "2026-11-20", "Koe-2026-11-20.md")
        assertTrue(rejectedUri in safIo.deletedUris)
        assertEquals("记录不存在", store.navigation.value.effectiveError)

        val brokenWriteUri = Uri.parse("content://docs/out/ioerr")
        bridge.exportWorkspacePayload = "# ok"
        safIo.outputProviders[brokenWriteUri] = { throw IOException("disk full") }
        picker.createResult = brokenWriteUri
        actions.requestExportWorkspace("rec-1", null, "ok.md")
        assertTrue(brokenWriteUri in safIo.deletedUris)
        assertEquals("无法写入目标文件。", store.navigation.value.effectiveError)
        assertTrue(exportRoot.listFiles().orEmpty().isEmpty())
    }

    @Test
    fun exportRecordsCopiesSortedMarkdownHandlesEmptyAndStopsCleanlyOnWriteError() = withTempRoots { importRoot, exportRoot ->
        val bridge = FileActionBridgeClient()
        val store = HostSessionStore("/tmp/koe-export-batch", bridge = bridge)
        val safIo = FakeSafIo()
        val actions = AndroidFileActions(safIo, importRoot, exportRoot, ioExecutor = Executor { it.run() })
        val picker = FakePickerHost({ actions })
        actions.onSessionBound(store)
        actions.attachActivity(picker)

        actions.requestExportRecords(listOf("", "   "))
        assertEquals(0, picker.treeLaunchCount)

        val treeUri = Uri.parse("content://docs/tree/exports")
        picker.treeResult = treeUri
        bridge.exportBatchFiles = mapOf(
            "b-second.md" to "# B",
            "a-first.md" to "# A",
            "ignored.tmp" to "skip",
        )
        actions.requestExportRecords(listOf("rec-1", " rec-2 ", "rec-1", ""))

        val cmd = bridge.commands.single()
        val ids = (cmd["recordIds"] as JsonArray).map { it.jsonPrimitive.content }
        assertEquals(listOf("rec-1", "rec-2"), ids)
        assertEquals(listOf("a-first.md", "b-second.md"), safIo.createdChildren.map { it.first })
        val firstUri = safIo.createdChildren[0].second
        val secondUri = safIo.createdChildren[1].second
        assertEquals("# A", safIo.outputBuffers[firstUri]?.toString(Charsets.UTF_8.name()))
        assertEquals("# B", safIo.outputBuffers[secondUri]?.toString(Charsets.UTF_8.name()))
        assertTrue(exportRoot.listFiles().orEmpty().isEmpty())

        safIo.createdChildren.clear()
        safIo.deletedUris.clear()
        val failUri = Uri.parse("content://docs/tree/exports/child/b-second.md")
        safIo.outputProviders[failUri] = { throw IOException("write failed") }
        actions.requestExportRecords(listOf("rec-1", "rec-2"))
        assertTrue(failUri in safIo.deletedUris)
        assertEquals("无法写入导出目录中的文件。", store.navigation.value.effectiveError)
        assertTrue(exportRoot.listFiles().orEmpty().isEmpty())
    }

    @Test
    fun cancelIsSilentAndSessionBoundCleansStaleDirsAndUnbindBlocksDispatch() = withTempRoots { importRoot, exportRoot ->
        val staleImport = File(importRoot, "stale-1").apply { mkdirs() }
        val staleExport = File(exportRoot, "stale-2").apply { mkdirs() }
        File(staleImport, "old.wav").writeText("old")
        File(staleExport, "old.md").writeText("old")

        val bridge = FileActionBridgeClient()
        val store = HostSessionStore("/tmp/koe-lifecycle", bridge = bridge)
        val safIo = FakeSafIo()
        val queuedJobs = mutableListOf<Runnable>()
        val actions = AndroidFileActions(
            safIo = safIo,
            importStagingRoot = importRoot,
            exportStagingRoot = exportRoot,
            ioExecutor = Executor { queuedJobs.add(it) },
        )

        actions.onSessionBound(store)
        queuedJobs.removeAt(0).run()
        assertFalse(staleImport.exists())
        assertFalse(staleExport.exists())

        val cancelPicker = FakePickerHost({ actions }, deferred = false)
        actions.attachActivity(cancelPicker)
        actions.requestImportFile()
        actions.requestExportWorkspace("rec-1", null, "x.md")
        actions.requestExportRecords(listOf("rec-1"))
        assertNull(store.navigation.value.effectiveError)
        assertTrue(bridge.commands.isEmpty())

        val uri = Uri.parse("content://docs/queued")
        safIo.displayNames[uri] = "queued.txt"
        safIo.inputStreams[uri] = { ByteArrayInputStream("hi".toByteArray()) }
        cancelPicker.openResult = uri
        actions.requestImportFile()
        assertEquals(1, queuedJobs.size)

        actions.onSessionUnbound()
        queuedJobs.removeAt(0).run()
        assertTrue("unbound store must not receive commands", bridge.commands.isEmpty())
        assertNull(store.navigation.value.effectiveError)
    }
}
