package com.semanticcraft.koe.platform.playback

import com.semanticcraft.koe.bridge.KoeNativeBridge
import com.semanticcraft.koe.core.HostBridgeClient
import com.semanticcraft.koe.core.HostJson
import com.semanticcraft.koe.core.HostSnapshot
import com.semanticcraft.koe.core.PcmIngestReceipt
import com.semanticcraft.koe.core.PcmIngestStatus
import com.semanticcraft.koe.core.PlaybackAssetSnapshot
import com.semanticcraft.koe.core.PlaybackLaneSnapshot
import com.semanticcraft.koe.core.PlaybackProgressReceipt
import com.semanticcraft.koe.core.PlaybackSnapshot
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long

internal data class ProgressReport(
    val recordId: String,
    val requestId: Long,
    val positionMs: Long,
    val isPlaying: Boolean,
)

internal class StatefulPlaybackBridgeClient(
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
