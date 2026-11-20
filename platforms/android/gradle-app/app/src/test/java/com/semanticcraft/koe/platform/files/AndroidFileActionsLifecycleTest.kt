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
import java.io.InputStream
import java.io.OutputStream
import java.nio.file.Files
import java.util.concurrent.Executor
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

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
        val payloads = mutableMapOf<Uri, ByteArray>()
        val outputs = mutableMapOf<Uri, ByteArrayOutputStream>()
        val deletedUris = mutableListOf<Uri>()

        override fun queryDisplayName(uri: Uri): String? = displayNames[uri]
        override fun queryMimeType(uri: Uri): String? = mimeTypes[uri]
        override fun openInputStream(uri: Uri): InputStream? = payloads[uri]?.let(::ByteArrayInputStream)
        override fun openOutputStream(uri: Uri): OutputStream = outputs.getOrPut(uri) { ByteArrayOutputStream() }
        override fun createChildMarkdownDocument(treeUri: Uri, fileName: String): Uri = Uri.parse("$treeUri/$fileName")
        override fun deleteDocumentBestEffort(uri: Uri) {
            deletedUris.add(uri)
        }
    }

    private class RecordingBridge : HostBridgeClient {
        private var current = HostSnapshot.empty.copy(generation = 1L)
        val commandTypes = mutableListOf<String>()
        var observedImportName: String? = null

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
                    observedImportName = File(obj["path"]?.jsonPrimitive?.content.orEmpty()).name
                }
                "export_workspace_markdown" -> {
                    File(obj["path"]?.jsonPrimitive?.content.orEmpty()).writeText("# 旋转后导出", Charsets.UTF_8)
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
}
