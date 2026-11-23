package com.semanticcraft.koe.core

import androidx.compose.ui.test.onNodeWithText
import com.semanticcraft.koe.BuildConfig
import com.semanticcraft.koe.bridge.KoeNativeBridge
import com.semanticcraft.koe.ui.createRobolectricComposeRule
import com.semanticcraft.koe.ui.screens.SettingsSheet
import com.semanticcraft.koe.ui.theme.KoeTheme
import java.io.BufferedReader
import java.io.File
import java.io.InputStreamReader
import java.net.InetAddress
import java.net.ServerSocket
import java.nio.charset.StandardCharsets
import java.nio.file.Files
import java.util.concurrent.atomic.AtomicBoolean
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], qualifiers = "w1024dp-h900dp-mdpi")
class RustSnapshotContractTest {
    @get:Rule
    val ui = createRobolectricComposeRule()

    @Test
    fun realRustSnapshotsDecodeCleanlyAcrossWorkflowAndAppUpdateLifecycle() {
        ensureHostJniLoaded()
        val workspaceDir = Files.createTempDirectory("koe-rust-kotlin-contract-").toFile()
        val downloadUrl = "https://github.com/semantic-craft/koe/releases/download/v9.9.9/Koe-9.9.9-macos-universal.zip"
        val releasePayload = """
            {
              "tag_name": "v9.9.9",
              "name": "Koe 9.9.9",
              "draft": false,
              "prerelease": false,
              "published_at": "2026-11-22T00:00:00Z",
              "html_url": "https://github.com/semantic-craft/koe/releases/tag/v9.9.9",
              "body": "跨端真实契约更新说明",
              "assets": [
                {
                  "name": "Koe-9.9.9-macos-universal.zip",
                  "size": 9876543,
                  "browser_download_url": "$downloadUrl"
                }
              ]
            }
        """.trimIndent().toByteArray(StandardCharsets.UTF_8)

        val server = LoopbackReleaseHttpServer(
            routes = mapOf(
                "/repos/semantic-craft/koe/releases/latest" to ("200 OK" to releasePayload),
                "/repos/semantic-craft/koe/releases/fail" to (
                    "500 Internal Server Error" to """{"message":"internal error"}""".toByteArray(StandardCharsets.UTF_8)
                    ),
            ),
        )
        server.start()

        val bridge = RecordingHostJniBridgeClient()
        val store = HostSessionStore(
            workspacePath = workspaceDir.absolutePath,
            bridge = bridge,
            autoOpen = true,
        )
        try {
            val port = server.port
            val baseNow = 1_800_100_000L

            store.send(
                HostAdapterEvent.SyncAppMetadata(
                    version = "2.7.1",
                    build = "17",
                    updateEndpoint = "http://127.0.0.1:$port/repos/semantic-craft/koe/releases/latest",
                    platform = "android",
                    hostDisplayName = "Android",
                    supportsSystemAudio = false,
                    supportsSelfUpdate = true,
                    nativeSpeechLabel = "Android 本机",
                ),
                nowEpochSec = baseNow,
            )
            assertNull(store.nativeError)

            store.send(HostCommand.CheckAppUpdate, nowEpochSec = baseNow + 1)
            val availableDeadline = System.nanoTime() + 4_000_000_000L
            while (store.settings.value.appUpdate.phase != "available" && System.nanoTime() < availableDeadline) {
                store.pollTimers(elapsedMs = 50L, nowEpochSec = baseNow + 2)
                Thread.sleep(15L)
            }

            val available = store.settings.value.appUpdate
            assertEquals("available", available.phase)
            assertTrue(available.isUpdateAvailable)
            assertEquals("9.9.9", available.latestVersion)
            assertEquals("Koe 9.9.9", available.releaseTitle)
            assertEquals("跨端真实契约更新说明", available.releaseNotes)
            assertEquals(downloadUrl, available.downloadUrl)
            assertEquals("Koe-9.9.9-macos-universal.zip", available.assetName)
            assertEquals(9_876_543L, available.assetSizeBytes)
            assertTrue(available.message?.contains("9.9.9") == true)

            ui.setContent { KoeTheme { SettingsSheet(store, {}) } }
            if (BuildConfig.ALLOW_SELF_UPDATE) {
                ui.onNodeWithText("新版本 9.9.9").assertExists()
                ui.onNodeWithText("跨端真实契约更新说明").assertExists()
                ui.onNodeWithText("下载更新").assertExists()
            }

            store.send(
                HostCommand.CreateNote(title = "契约笔记", text = "真实 Rust 快照解码校验", stayOnPage = false),
                nowEpochSec = baseNow + 3,
            )
            val createdId = store.records.value.firstOrNull { it.title == "契约笔记" }?.id
            assertNotNull(createdId)

            store.send(HostCommand.SelectRecord(createdId!!), nowEpochSec = baseNow + 4)
            assertEquals(createdId, store.recordDetail.value.detail?.id)
            assertEquals("契约笔记", store.recordDetail.value.detail?.title)

            store.send(HostCommand.TrashRecord(createdId), nowEpochSec = baseNow + 5)
            assertTrue(store.records.value.none { it.id == createdId })
            assertTrue(store.trashRecords.value.any { it.id == createdId })

            store.send(HostCommand.RestoreRecord(createdId), nowEpochSec = baseNow + 6)
            assertTrue(store.records.value.any { it.id == createdId })
            assertTrue(store.trashRecords.value.none { it.id == createdId })

            store.send(
                HostAdapterEvent.SyncAppMetadata(
                    version = "2.7.1",
                    build = "17",
                    updateEndpoint = "http://127.0.0.1:$port/repos/semantic-craft/koe/releases/fail",
                    platform = "android",
                    hostDisplayName = "Android",
                    supportsSystemAudio = false,
                    supportsSelfUpdate = true,
                    nativeSpeechLabel = "Android 本机",
                ),
                nowEpochSec = baseNow + 7,
            )
            store.send(HostCommand.CheckAppUpdate, nowEpochSec = baseNow + 8)
            val failedDeadline = System.nanoTime() + 4_000_000_000L
            while (store.settings.value.appUpdate.phase != "failed" && System.nanoTime() < failedDeadline) {
                store.pollTimers(elapsedMs = 50L, nowEpochSec = baseNow + 9)
                Thread.sleep(15L)
            }

            val failed = store.settings.value.appUpdate
            assertEquals("failed", failed.phase)
            assertFalse(failed.isUpdateAvailable)
            assertFalse(failed.message.isNullOrBlank())
            assertNull(failed.latestVersion)
            assertNull(failed.downloadUrl)

            if (BuildConfig.ALLOW_SELF_UPDATE) {
                ui.waitForIdle()
                ui.onNodeWithText(failed.message!!).assertExists()
                ui.onNodeWithText("下载更新").assertDoesNotExist()
            }

            assertTrue(bridge.rawSnapshots.size >= 8)
            for (rawJson in bridge.rawSnapshots) {
                val decoded = HostJson.json.decodeFromString(HostSnapshot.serializer(), rawJson)
                assertEquals(HostSessionStore.EXPECTED_ABI_VERSION, decoded.version)
            }
        } finally {
            store.shutdown()
            server.close()
            workspaceDir.deleteRecursively()
        }
    }

    @Test
    fun realRustSingleSourceOfTruthSnapshotContractDecodesAllAuthoritativeFields() {
        ensureHostJniLoaded()
        val workspaceDir = Files.createTempDirectory("koe-rust-kotlin-ssot-").toFile()
        val bridge = RecordingHostJniBridgeClient()
        val store = HostSessionStore(
            workspacePath = workspaceDir.absolutePath,
            bridge = bridge,
            autoOpen = true,
        )
        try {
            val baseNow = 1_800_310_000L
            val initialProvider = store.settings.value.provider
            val catalog = checkNotNull(initialProvider.catalog)
            assertEquals(4, catalog.qwenAsrModels.size)
            assertEquals(2, catalog.deepseekLlmModels.size)
            assertEquals("dashscope.aliyuncs.com", catalog.defaultQwenHost)
            assertEquals(".cn-beijing.maas.aliyuncs.com", catalog.qwenWorkspaceHostSuffix)
            assertEquals("https://api.deepseek.com/v1/tools/asr", catalog.defaultDeepseekAsrEndpoint)
            assertEquals("https://api.deepseek.com/chat/completions", catalog.defaultDeepseekChatEndpoint)
            assertEquals("qwen-audio-3.1-asr-flash-streaming", catalog.defaultQwenAsrModel)
            assertEquals("deepseek-flash", catalog.defaultDeepseekLlmModel)
            assertEquals("wss://dashscope.aliyuncs.com/api-ws/v1/inference", initialProvider.defaultAsrEndpoint)
            assertEquals("https://api.deepseek.com/chat/completions", initialProvider.defaultChatEndpoint)

            val wsDraft = ModelSettingsDraft(
                asrProvider = "qwen",
                qwenAsrModel = "qwen-audio-3.1-asr-flash-filetrans",
                llmProvider = "deepseek",
                deepseekLlmModel = "deepseek-flash",
                qwenWorkspaceId = "ws-and-1",
            )
            store.send(wsDraft.toConfigureProviderCommand(), nowEpochSec = baseNow + 1)
            val expectedWsEndpoint =
                "https://ws-and-1.cn-beijing.maas.aliyuncs.com/api/v1/services/audio/asr/transcription"
            assertEquals(expectedWsEndpoint, store.settings.value.provider.defaultAsrEndpoint)
            assertEquals(expectedWsEndpoint, store.settings.value.provider.asrEndpoint)

            assertEquals(0, store.device.value.transferErrorCode)
            assertFalse(store.device.value.audioDecryptReady)
            assertTrue(store.settings.value.speech.models.isNotEmpty())
            assertTrue(store.settings.value.speech.models.all { it.languages.isNotEmpty() })

            store.send(
                HostCommand.CreateNote(title = "Android 单源笔记", text = "第一句。\n第二句。", stayOnPage = false),
                nowEpochSec = baseNow + 2,
            )
            val noteDetail = checkNotNull(store.recordDetail.value.detail)
            val noteRow = checkNotNull(store.records.value.firstOrNull { it.id == noteDetail.id })
            assertTrue(noteRow.canTrash)
            assertFalse(noteRow.isTranscribing)
            assertTrue(noteDetail.canTrash)

            store.send(HostCommand.SetRecordArchived(noteDetail.id, archived = true), nowEpochSec = baseNow + 3)
            assertFalse(checkNotNull(store.records.value.firstOrNull { it.id == noteDetail.id }).canTrash)
            assertFalse(checkNotNull(store.recordDetail.value.detail).canTrash)
            store.send(HostCommand.SetRecordArchived(noteDetail.id, archived = false), nowEpochSec = baseNow + 4)
            assertTrue(checkNotNull(store.records.value.firstOrNull { it.id == noteDetail.id }).canTrash)

            val firstSeg = noteDetail.segments.first()
            store.send(HostCommand.CreateTask(noteDetail.id, firstSeg.id), nowEpochSec = baseNow + 5)
            store.send(HostCommand.SaveMemory(noteDetail.id, firstSeg.id), nowEpochSec = baseNow + 6)
            val taskId = store.tasks.value.first().id
            val memoryId = store.memories.value.first().id
            store.send(HostCommand.ReviewItem(taskId, ReviewDecision.RESET), nowEpochSec = baseNow + 7)
            store.send(HostCommand.ReviewItem(memoryId, ReviewDecision.RESET), nowEpochSec = baseNow + 8)

            val latestSnap = HostJson.json.decodeFromString(HostSnapshot.serializer(), bridge.rawSnapshots.last())
            assertEquals(
                ReviewCountsSnapshot(
                    proposedTaskCount = 1,
                    proposedMemoryCount = 1,
                    proposedActionCount = 2,
                    activeMemoryCount = 1,
                ),
                latestSnap.reviewCounts,
            )
            assertEquals(2, store.today.value.proposedActionCount)

            store.send(HostCommand.ReviewItem(memoryId, ReviewDecision.DISMISS), nowEpochSec = baseNow + 9)
            val dismissedSnap = HostJson.json.decodeFromString(HostSnapshot.serializer(), bridge.rawSnapshots.last())
            assertEquals(0, dismissedSnap.reviewCounts?.activeMemoryCount)
            assertEquals(1, store.today.value.proposedActionCount)

            store.send(
                HostCommand.StartCaptureMode(mode = CaptureMode.QUICK_NOTE, stayOnPage = true),
                nowEpochSec = baseNow + 10,
            )
            val mic = checkNotNull(store.currentMicrophone())
            store.send(
                HostAdapterEvent.MicrophonePrepared(
                    recordId = mic.recordId,
                    sessionId = mic.sessionId,
                    epoch = 0L,
                    clockNs = 1_000_000_000L,
                ),
                nowEpochSec = baseNow + 10,
            )
            store.send(
                HostAdapterEvent.MicrophoneStarted(
                    recordId = mic.recordId,
                    sessionId = mic.sessionId,
                    lane = "microphone",
                    sampleRate = 16_000,
                ),
                nowEpochSec = baseNow + 10,
            )
            val ingest = store.ingestMicrophonePcm(
                recordId = mic.recordId,
                sessionId = mic.sessionId,
                lane = "microphone",
                sequence = 0L,
                epoch = 0L,
                capturedStartNs = 1_000_000_000L,
                samples = ShortArray(320) { 240 },
                sampleCount = 320,
                nowEpochSec = baseNow + 10,
            )
            assertEquals(PcmIngestStatus.ACCEPTED, ingest.status)
            store.send(HostCommand.SelectRecord(mic.recordId), nowEpochSec = baseNow + 10)
            val liveRow = checkNotNull(store.records.value.firstOrNull { it.id == mic.recordId })
            assertFalse(liveRow.canTrash)
            assertTrue(liveRow.isTranscribing)
            assertFalse(checkNotNull(store.recordDetail.value.detail).canTrash)

            store.send(HostCommand.CaptureActionCommand(CaptureAction.END), nowEpochSec = baseNow + 11)
            store.send(
                HostAdapterEvent.MicrophoneStopped(
                    recordId = mic.recordId,
                    sessionId = mic.sessionId,
                    lane = "microphone",
                    sequence = 1L,
                    epoch = 0L,
                ),
                nowEpochSec = baseNow + 11,
            )
            store.send(HostCommand.SelectRecord(mic.recordId), nowEpochSec = baseNow + 12)
            val capturedDetail = checkNotNull(store.recordDetail.value.detail)
            val micLane = checkNotNull(capturedDetail.captureLanes.firstOrNull { it.lane == "microphone" })
            assertEquals(16_000, micLane.sampleRate)
            assertTrue(micLane.durationMs > 0L)
            assertEquals(320L, micLane.timeline.first().sampleCount)
        } finally {
            store.shutdown()
            workspaceDir.deleteRecursively()
        }
    }

    private class LoopbackReleaseHttpServer(
        private val routes: Map<String, Pair<String, ByteArray>>,
    ) : AutoCloseable {
        private val socket = ServerSocket(0, 8, InetAddress.getByName("127.0.0.1"))
        private val running = AtomicBoolean(true)
        private val thread = Thread(::serve, "koe-contract-release-http").apply { isDaemon = true }

        val port: Int get() = socket.localPort

        fun start() = thread.start()

        private fun serve() {
            while (running.get()) {
                val client = try {
                    socket.accept()
                } catch (_: Exception) {
                    break
                }
                client.use { conn ->
                    conn.soTimeout = 3000
                    val reader = BufferedReader(InputStreamReader(conn.getInputStream(), StandardCharsets.US_ASCII))
                    val requestLine = reader.readLine() ?: return@use
                    while (true) {
                        val header = reader.readLine() ?: break
                        if (header.isEmpty()) break
                    }
                    val path = requestLine.split(' ').getOrNull(1).orEmpty()
                    val (status, body) = routes[path] ?: ("404 Not Found" to ByteArray(0))
                    val headers = "HTTP/1.1 $status\r\nContent-Type: application/json\r\nContent-Length: ${body.size}\r\nConnection: close\r\n\r\n"
                    val out = conn.getOutputStream()
                    out.write(headers.toByteArray(StandardCharsets.US_ASCII))
                    out.write(body)
                    out.flush()
                }
            }
        }

        override fun close() {
            running.set(false)
            runCatching { socket.close() }
        }
    }

    private class RecordingHostJniBridgeClient : HostBridgeClient {
        val rawSnapshots = mutableListOf<String>()

        override fun apiVersion(): Int = KoeNativeBridge.nativeApiVersion()

        override fun sessionCreate(directory: String): Long =
            KoeNativeBridge.nativeSessionCreate(directory.toByteArray(StandardCharsets.UTF_8))

        override fun sessionCreateWithCredentials(
            directory: String,
            credentialBridge: KoeNativeBridge.CredentialBridge,
            isolated: Boolean,
        ): Long = KoeNativeBridge.nativeSessionCreateWithCredentials(
            directory.toByteArray(StandardCharsets.UTF_8),
            credentialBridge,
            isolated,
        )

        override fun sessionDestroy(handle: Long): Boolean = KoeNativeBridge.nativeSessionDestroy(handle)

        override fun sessionGeneration(handle: Long): Long = KoeNativeBridge.nativeSessionGeneration(handle)

        override fun sessionSnapshotJson(handle: Long, nowEpochSec: Long): String? {
            val raw = KoeNativeBridge.nativeSessionSnapshotJson(handle, nowEpochSec) ?: return null
            return String(raw, StandardCharsets.UTF_8).also { rawSnapshots.add(it) }
        }

        override fun sessionDispatchJson(handle: Long, commandJson: String, nowEpochSec: Long): String? {
            val raw = KoeNativeBridge.nativeSessionDispatchJson(
                handle,
                commandJson.toByteArray(StandardCharsets.UTF_8),
                nowEpochSec,
            ) ?: return null
            return String(raw, StandardCharsets.UTF_8).also { rawSnapshots.add(it) }
        }

        override fun sessionIngestBle(handle: Long, bytes: ByteArray, nowEpochSec: Long): Long =
            KoeNativeBridge.nativeSessionIngestBle(handle, bytes, nowEpochSec)

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
        ): PcmIngestReceipt {
            val raw = KoeNativeBridge.nativeSessionIngestPcm(
                handle,
                recordId.toByteArray(StandardCharsets.UTF_8),
                sessionId.toByteArray(StandardCharsets.UTF_8),
                lane.toByteArray(StandardCharsets.UTF_8),
                sequence,
                epoch,
                capturedStartNs ?: 0L,
                capturedStartNs != null,
                samples,
                sampleCount,
                nowEpochSec,
            ) ?: return PcmIngestReceipt(0L, 0L, PcmIngestStatus.REJECTED)
            return PcmIngestReceipt(raw[0], raw[1], PcmIngestStatus.fromCode(raw[2].toInt()))
        }

        override fun sessionReportPlaybackProgress(
            handle: Long,
            recordId: String,
            requestId: Long,
            positionMs: Long,
            isPlaying: Boolean,
            lastProjectedNowSec: Long,
            nowEpochSec: Long,
        ): PlaybackProgressReceipt {
            val raw = KoeNativeBridge.nativeSessionReportPlaybackProgress(
                handle,
                recordId.toByteArray(StandardCharsets.UTF_8),
                requestId,
                positionMs,
                isPlaying,
                lastProjectedNowSec,
                nowEpochSec,
            ) ?: return PlaybackProgressReceipt(0L, 0L, 0L, nowEpochSec, false, false, true)
            return PlaybackProgressReceipt(
                raw[0], raw[1], raw[2], raw[3], raw[4] != 0L, raw[5] != 0L, raw[6] != 0L,
            )
        }

        override fun sessionDrainBleTx(handle: Long): ByteArray? = KoeNativeBridge.nativeSessionDrainBleTx(handle)

        override fun sessionDrainLocalAsr(handle: Long): ByteArray? =
            KoeNativeBridge.nativeSessionDrainLocalAsr(handle)

        override fun sessionPollTimers(handle: Long, elapsedMs: Long, nowEpochSec: Long): Long =
            KoeNativeBridge.nativeSessionPollTimers(handle, elapsedMs, nowEpochSec)
    }

    companion object {
        private val loadLock = Any()

        @Volatile
        private var loaded = false

        private fun ensureHostJniLoaded() {
            if (loaded) return
            synchronized(loadLock) {
                if (loaded) return
                val ext = if (System.getProperty("os.name").orEmpty().lowercase().contains("mac")) "dylib" else "so"
                val repoRoot = findRepoRoot()
                    ?: error("Repository root containing platforms/android/tests/jni/test-jni-host.sh not found")
                val jniHostDir = File(repoRoot, "target/jni-host")
                val hostLib = File(jniHostDir, "libkoe_host_api.$ext")
                val jniTestLib = File(jniHostDir, "libkoe_android_test.$ext")
                if (!hostLib.isFile || !jniTestLib.isFile) {
                    val script = File(repoRoot, "platforms/android/tests/jni/test-jni-host.sh")
                    val process = ProcessBuilder(script.absolutePath)
                        .directory(repoRoot)
                        .redirectErrorStream(true)
                        .start()
                    val output = process.inputStream.bufferedReader().readText()
                    val exit = process.waitFor()
                    check(exit == 0 && hostLib.isFile && jniTestLib.isFile) {
                        "Failed to build host JNI test libraries via ${script.absolutePath} (exit=$exit):\n$output"
                    }
                }
                System.load(hostLib.absolutePath)
                System.load(jniTestLib.absolutePath)
                loaded = true
            }
        }

        private fun findRepoRoot(): File? {
            var cursor: File? = File(".").canonicalFile
            while (cursor != null) {
                if (File(cursor, "platforms/android/tests/jni/test-jni-host.sh").isFile) {
                    return cursor
                }
                cursor = cursor.parentFile
            }
            return null
        }
    }
}
