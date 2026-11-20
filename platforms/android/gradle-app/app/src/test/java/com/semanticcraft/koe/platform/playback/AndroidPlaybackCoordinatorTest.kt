package com.semanticcraft.koe.platform.playback

import com.semanticcraft.koe.bridge.KoeNativeBridge
import com.semanticcraft.koe.core.HostBridgeClient
import com.semanticcraft.koe.core.HostCommand
import com.semanticcraft.koe.core.HostJson
import com.semanticcraft.koe.core.HostSessionStore
import com.semanticcraft.koe.core.HostSnapshot
import com.semanticcraft.koe.core.PcmIngestReceipt
import com.semanticcraft.koe.core.PcmIngestStatus
import com.semanticcraft.koe.core.PlaybackAssetSnapshot
import com.semanticcraft.koe.core.PlaybackLaneSnapshot
import com.semanticcraft.koe.core.PlaybackProgressReceipt
import com.semanticcraft.koe.core.PlaybackSnapshot
import com.semanticcraft.koe.platform.AndroidHostCoordinator
import com.semanticcraft.koe.platform.TickScheduler
import com.semanticcraft.koe.platform.capture.AudioFocusController
import java.io.IOException
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class AndroidPlaybackCoordinatorTest {
    private class ManualTickScheduler : TickScheduler {
        override fun schedulePeriodic(intervalMs: Long, onTick: () -> Unit): AutoCloseable =
            AutoCloseable {}
    }

    private class FakeAudioFocusController(
        var grantFocus: Boolean = true,
    ) : AudioFocusController {
        var requestCount = 0
        var abandonCount = 0
        var activeLossCallback: (() -> Unit)? = null

        override fun requestFocus(onFocusLost: () -> Unit): Boolean {
            requestCount += 1
            if (!grantFocus) return false
            activeLossCallback = onFocusLost
            return true
        }

        override fun abandonFocus() {
            abandonCount += 1
            activeLossCallback = null
        }

        fun triggerFocusLoss() {
            activeLossCallback?.invoke()
        }
    }

    private class FakeAudioPlaybackSink(
        val plan: PlaybackAssetSnapshot,
        override val durationMs: Long = (plan.durationNs / 1_000_000L).coerceAtLeast(1_000L),
    ) : AudioPlaybackSink {
        override var currentPositionMs: Long = 0L
        override var isPlaying: Boolean = false
        override var isCompleted: Boolean = false
        override var failureMessage: String? = null

        val seekHistory = mutableListOf<Long>()
        var playCount = 0
        var pauseCount = 0
        var closed = false

        override fun seekToMs(positionMs: Long) {
            seekHistory.add(positionMs)
            currentPositionMs = positionMs.coerceIn(0L, durationMs)
            isCompleted = false
        }

        override fun play() {
            playCount += 1
            if (currentPositionMs >= durationMs) {
                isCompleted = true
                isPlaying = false
            } else {
                isPlaying = true
            }
        }

        override fun pause() {
            pauseCount += 1
            isPlaying = false
        }

        override fun close() {
            closed = true
            isPlaying = false
        }
    }

    private data class ProgressReport(
        val recordId: String,
        val requestId: Long,
        val positionMs: Long,
        val isPlaying: Boolean,
    )

    private class StatefulPlaybackBridgeClient(
        private val assetsByKey: Map<Pair<String, String>, PlaybackAssetSnapshot>,
        private val durationByRecord: Map<String, Long>,
    ) : HostBridgeClient {
        var snapshot: HostSnapshot = HostSnapshot.empty.copy(generation = 1L)
        val dispatchedCommands = mutableListOf<JsonObject>()
        val progressReports = mutableListOf<ProgressReport>()

        override fun apiVersion(): Int = 2
        override fun sessionCreate(directory: String): Long = 700L
        override fun sessionCreateWithCredentials(
            directory: String,
            credentialBridge: KoeNativeBridge.CredentialBridge,
            isolated: Boolean,
        ): Long = 700L
        override fun sessionDestroy(handle: Long): Boolean = true
        override fun sessionGeneration(handle: Long): Long = snapshot.generation

        override fun sessionSnapshotJson(handle: Long, nowEpochSec: Long): String =
            HostJson.json.encodeToString(HostSnapshot.serializer(), snapshot)

        override fun sessionDispatchJson(handle: Long, commandJson: String, nowEpochSec: Long): String {
            val obj = HostJson.json.parseToJsonElement(commandJson) as JsonObject
            dispatchedCommands.add(obj)
            val type = obj["type"]?.jsonPrimitive?.content
            when (type) {
                "select_record" -> {
                    val recordId = obj["recordId"]?.jsonPrimitive?.content ?: ""
                    val defaultLane = "microphone"
                    val asset = assetsByKey[recordId to defaultLane]
                    snapshot = snapshot.copy(
                        generation = snapshot.generation + 1L,
                        selectedRecordId = recordId,
                        playback = PlaybackSnapshot(
                            recordId = recordId,
                            positionMs = 0L,
                            isPlaying = false,
                            requestId = snapshot.playback.requestId + 1L,
                            lane = defaultLane,
                            lanes = listOf(
                                PlaybackLaneSnapshot("microphone", available = assetsByKey.containsKey(recordId to "microphone")),
                                PlaybackLaneSnapshot("system", available = assetsByKey.containsKey(recordId to "system")),
                            ),
                            asset = asset,
                        ),
                    )
                }
                "playback" -> {
                    val isPlaying = obj["isPlaying"]?.jsonPrimitive?.boolean ?: false
                    snapshot = snapshot.copy(
                        generation = snapshot.generation + 1L,
                        playback = snapshot.playback.copy(
                            isPlaying = isPlaying,
                            requestId = snapshot.playback.requestId + 1L,
                        ),
                    )
                }
                "seek" -> {
                    val pos = obj["positionMs"]?.jsonPrimitive?.long ?: 0L
                    val maxDuration = durationByRecord[snapshot.playback.recordId] ?: pos
                    snapshot = snapshot.copy(
                        generation = snapshot.generation + 1L,
                        playback = snapshot.playback.copy(
                            positionMs = pos.coerceIn(0L, maxDuration),
                            requestId = snapshot.playback.requestId + 1L,
                        ),
                    )
                }
                "select_playback_lane" -> {
                    val lane = obj["lane"]?.jsonPrimitive?.content ?: "microphone"
                    val recordId = snapshot.playback.recordId
                    val asset = if (recordId != null) assetsByKey[recordId to lane] else null
                    snapshot = snapshot.copy(
                        generation = snapshot.generation + 1L,
                        playback = snapshot.playback.copy(
                            lane = lane,
                            asset = asset,
                            requestId = snapshot.playback.requestId + 1L,
                        ),
                    )
                }
                "trash_record" -> {
                    snapshot = snapshot.copy(
                        generation = snapshot.generation + 1L,
                        selectedRecordId = null,
                        playback = PlaybackSnapshot.empty.copy(
                            requestId = snapshot.playback.requestId + 1L,
                        ),
                    )
                }
            }
            return sessionSnapshotJson(handle, nowEpochSec)
        }

        override fun sessionIngestBle(handle: Long, bytes: ByteArray, nowEpochSec: Long): Long = snapshot.generation

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
        ): PcmIngestReceipt = PcmIngestReceipt(snapshot.generation, sequence + 1L, PcmIngestStatus.ACCEPTED)

        override fun sessionReportPlaybackProgress(
            handle: Long,
            recordId: String,
            requestId: Long,
            positionMs: Long,
            isPlaying: Boolean,
            lastProjectedNowSec: Long,
            nowEpochSec: Long,
        ): PlaybackProgressReceipt {
            progressReports.add(ProgressReport(recordId, requestId, positionMs, isPlaying))
            if (snapshot.playback.recordId != recordId || snapshot.playback.requestId != requestId) {
                return PlaybackProgressReceipt(
                    generation = snapshot.generation,
                    prevGeneration = snapshot.generation,
                    positionMs = 0L,
                    nowEpochSec = nowEpochSec,
                    isPlaying = false,
                    applied = false,
                    needsFullSnapshot = false,
                )
            }
            val maxDuration = durationByRecord[recordId] ?: positionMs
            val clamped = positionMs.coerceIn(0L, maxDuration)
            val prevGen = snapshot.generation
            val nextGen = prevGen + 1L
            snapshot = snapshot.updatingPlayback(
                generation = nextGen,
                positionMs = clamped,
                isPlaying = isPlaying,
            )
            return PlaybackProgressReceipt(
                generation = nextGen,
                prevGeneration = prevGen,
                positionMs = clamped,
                nowEpochSec = nowEpochSec,
                isPlaying = isPlaying,
                applied = true,
                needsFullSnapshot = false,
            )
        }

        override fun sessionDrainBleTx(handle: Long): ByteArray = ByteArray(0)
        override fun sessionDrainLocalAsr(handle: Long): ByteArray = ByteArray(0)
        override fun sessionPollTimers(handle: Long, elapsedMs: Long, nowEpochSec: Long): Long = snapshot.generation
    }

    private data class Harness(
        val bridge: StatefulPlaybackBridgeClient,
        val store: HostSessionStore,
        val focus: FakeAudioFocusController,
        val coordinator: AndroidPlaybackCoordinator,
        val hostCoordinator: AndroidHostCoordinator,
        val openedSinks: MutableList<FakeAudioPlaybackSink>,
        var openError: Throwable? = null,
        var openAttempts: Int = 0,
    )

    private fun createHarness(): Harness {
        val assets = mapOf(
            ("rec-1" to "microphone") to PlaybackAssetSnapshot(
                audioPath = "/tmp/rec-1-mic.wav",
                sampleRate = 16_000,
                durationNs = 2_000_000_000L,
            ),
            ("rec-1" to "system") to PlaybackAssetSnapshot(
                audioPath = "/tmp/rec-1-sys.wav",
                sampleRate = 16_000,
                durationNs = 2_000_000_000L,
            ),
            ("rec-2" to "microphone") to PlaybackAssetSnapshot(
                audioPath = "/tmp/rec-2-mic.wav",
                sampleRate = 16_000,
                durationNs = 1_500_000_000L,
            ),
        )
        val durations = mapOf("rec-1" to 2_000L, "rec-2" to 1_500L)
        val bridge = StatefulPlaybackBridgeClient(assets, durations)
        val store = HostSessionStore(workspacePath = "/tmp/koe-playback-test", bridge = bridge)
        val focus = FakeAudioFocusController()
        val openedSinks = mutableListOf<FakeAudioPlaybackSink>()
        lateinit var harness: Harness
        val playbackCoordinator = AndroidPlaybackCoordinator(
            sinkFactory = AudioPlaybackSinkFactory { plan ->
                harness.openAttempts += 1
                harness.openError?.let { throw it }
                FakeAudioPlaybackSink(plan).also { openedSinks.add(it) }
            },
            focusController = focus,
        )
        val hostCoordinator = AndroidHostCoordinator(
            tickIntervalMs = 250L,
            scheduler = ManualTickScheduler(),
            clockElapsedMs = { 0L },
        )
        harness = Harness(
            bridge = bridge,
            store = store,
            focus = focus,
            coordinator = playbackCoordinator,
            hostCoordinator = hostCoordinator,
            openedSinks = openedSinks,
        )
        hostCoordinator.registerAdapter(playbackCoordinator)
        hostCoordinator.bind(store)
        return harness
    }

    @Test
    fun playPauseSeekAndDeltaProgressReporting() {
        val h = createHarness()

        h.store.send(HostCommand.SelectRecord("rec-1"))
        assertEquals(1, h.openedSinks.size)
        val sink = h.openedSinks.single()
        assertFalse(sink.isPlaying)
        assertEquals(0, h.focus.requestCount)

        repeat(4) { h.hostCoordinator.tickOnce() }
        assertTrue(h.bridge.progressReports.isEmpty())

        h.store.send(HostCommand.Playback(isPlaying = true))
        assertTrue(sink.isPlaying)
        assertEquals(1, h.focus.requestCount)
        assertEquals(0, h.focus.abandonCount)
        assertTrue(h.bridge.progressReports.isEmpty())

        h.hostCoordinator.tickOnce()
        assertTrue(h.bridge.progressReports.isEmpty())

        sink.currentPositionMs = 250L
        h.hostCoordinator.tickOnce()
        assertEquals(1, h.bridge.progressReports.size)
        assertEquals(250L, h.bridge.progressReports.last().positionMs)
        assertTrue(h.bridge.progressReports.last().isPlaying)
        assertEquals(250L, h.store.playback.value.positionMs)

        h.hostCoordinator.tickOnce()
        assertEquals(1, h.bridge.progressReports.size)

        h.store.send(HostCommand.Seek(800L))
        assertEquals(listOf(800L), sink.seekHistory)
        assertTrue(sink.isPlaying)
        assertEquals(1, h.focus.requestCount)

        sink.currentPositionMs = 1_050L
        h.hostCoordinator.tickOnce()
        assertEquals(2, h.bridge.progressReports.size)
        assertEquals(1_050L, h.bridge.progressReports.last().positionMs)

        h.store.send(HostCommand.Playback(isPlaying = false))
        assertFalse(sink.isPlaying)
        assertEquals(1, h.focus.abandonCount)

        repeat(3) { h.hostCoordinator.tickOnce() }
        assertEquals(1, h.focus.abandonCount)
        assertEquals(2, h.bridge.progressReports.size)
    }

    @Test
    fun completionAtEofPausesSinkAbandonsFocusAndReportsNotPlaying() {
        val h = createHarness()

        h.store.send(HostCommand.SelectRecord("rec-1"))
        h.store.send(HostCommand.Playback(isPlaying = true))
        val sink = h.openedSinks.single()

        sink.currentPositionMs = 2_000L
        sink.isCompleted = true
        h.hostCoordinator.tickOnce()

        assertFalse(sink.isPlaying)
        assertEquals(1, h.focus.abandonCount)
        assertFalse(h.store.playback.value.isPlaying)
        assertEquals(2_000L, h.store.playback.value.positionMs)
        assertEquals(1, h.bridge.progressReports.size)
        assertFalse(h.bridge.progressReports.last().isPlaying)
        assertEquals(2_000L, h.bridge.progressReports.last().positionMs)
    }

    @Test
    fun audioFocusLossDispatchesPlaybackFalseAndPauses() {
        val h = createHarness()

        h.store.send(HostCommand.SelectRecord("rec-1"))
        h.store.send(HostCommand.Playback(isPlaying = true))
        h.store.send(HostCommand.Seek(400L))
        val sink = h.openedSinks.single()
        assertTrue(sink.isPlaying)

        h.focus.triggerFocusLoss()
        assertFalse(h.store.playback.value.isPlaying)
        assertFalse(sink.isPlaying)
        assertEquals(1, h.focus.abandonCount)

        val playbackCommands = h.bridge.dispatchedCommands.filter {
            it["type"]?.jsonPrimitive?.content == "playback"
        }
        assertEquals(false, playbackCommands.last()["isPlaying"]?.jsonPrimitive?.boolean)

        val countBefore = playbackCommands.size
        h.focus.triggerFocusLoss()
        val countAfter = h.bridge.dispatchedCommands.count {
            it["type"]?.jsonPrimitive?.content == "playback"
        }
        assertEquals(countBefore, countAfter)
    }

    @Test
    fun openFailureReportsNativeErrorDoesNotThrashAndRecoversOnNewRequestId() {
        val h = createHarness()
        h.openError = IOException("missing wav")

        h.store.send(HostCommand.SelectRecord("rec-1"))
        assertEquals(1, h.openAttempts)
        assertEquals(
            "无法播放这段音频。原始文件可能不可用，或格式不受支持。",
            h.store.nativeError,
        )
        assertEquals(1, h.bridge.progressReports.size)
        assertFalse(h.bridge.progressReports.last().isPlaying)

        repeat(5) { h.hostCoordinator.tickOnce() }
        assertEquals(1, h.openAttempts)

        h.openError = null
        h.store.send(HostCommand.Seek(350L))
        assertEquals(2, h.openAttempts)
        assertNull(h.store.nativeError)
        assertEquals(1, h.openedSinks.size)
        assertEquals(listOf(350L), h.openedSinks.single().seekHistory)
    }

    @Test
    fun runtimeSinkFailureClosesSinkAbandonsFocusAndReportsNativeError() {
        val h = createHarness()

        h.store.send(HostCommand.SelectRecord("rec-1"))
        h.store.send(HostCommand.Playback(isPlaying = true))
        val sink = h.openedSinks.single()
        assertTrue(sink.isPlaying)

        sink.failureMessage = "AudioTrack write error -32"
        h.hostCoordinator.tickOnce()

        assertTrue(sink.closed)
        assertEquals(1, h.focus.abandonCount)
        assertFalse(h.store.playback.value.isPlaying)
        assertEquals(
            "无法播放这段音频。原始文件可能不可用，或格式不受支持。",
            h.store.nativeError,
        )

        repeat(3) { h.hostCoordinator.tickOnce() }
        assertEquals(1, h.openAttempts)
    }

    @Test
    fun switchingLaneRecordTrashAndShutdownClosePreviousSinkAndAbandonFocus() {
        val h = createHarness()

        h.store.send(HostCommand.SelectRecord("rec-1"))
        h.store.send(HostCommand.Seek(500L))
        h.store.send(HostCommand.Playback(isPlaying = true))
        val micSink = h.openedSinks[0]
        assertTrue(micSink.isPlaying)

        h.store.send(HostCommand.SelectPlaybackLane("system"))
        assertTrue(micSink.closed)
        assertEquals(2, h.openedSinks.size)
        val sysSink = h.openedSinks[1]
        assertEquals(listOf(500L), sysSink.seekHistory)
        assertTrue(sysSink.isPlaying)

        h.store.send(HostCommand.SelectRecord("rec-2"))
        assertTrue(sysSink.closed)
        assertEquals(3, h.openedSinks.size)
        val rec2Sink = h.openedSinks[2]
        assertFalse(rec2Sink.isPlaying)

        h.store.send(HostCommand.Playback(isPlaying = true))
        assertTrue(rec2Sink.isPlaying)
        h.store.send(HostCommand.TrashRecord("rec-2"))
        assertTrue(rec2Sink.closed)
        assertNull(h.store.playback.value.recordId)

        h.store.send(HostCommand.SelectRecord("rec-1"))
        h.store.send(HostCommand.Playback(isPlaying = true))
        val lastSink = h.openedSinks.last()
        assertTrue(lastSink.isPlaying)
        val abandonsBeforeShutdown = h.focus.abandonCount
        h.hostCoordinator.shutdown()
        assertTrue(lastSink.closed)
        assertEquals(abandonsBeforeShutdown + 1, h.focus.abandonCount)
    }
}
