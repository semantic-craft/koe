package com.semanticcraft.koe.platform.capture

import com.semanticcraft.koe.bridge.KoeNativeBridge
import com.semanticcraft.koe.core.ActiveCaptureSnapshot
import com.semanticcraft.koe.core.CaptureAction
import com.semanticcraft.koe.core.CaptureLaneSnapshot
import com.semanticcraft.koe.core.CaptureMode
import com.semanticcraft.koe.core.HostBridgeClient
import com.semanticcraft.koe.core.HostJson
import com.semanticcraft.koe.core.HostSnapshot
import com.semanticcraft.koe.core.MicrophoneSnapshot
import com.semanticcraft.koe.core.PcmIngestReceipt
import com.semanticcraft.koe.core.PcmIngestStatus
import com.semanticcraft.koe.core.PlaybackProgressReceipt
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long

internal data class IngestedChunk(
    val sequence: Long,
    val epoch: Long,
    val capturedStartNs: Long?,
    val sampleCount: Int,
)

internal class StatefulCaptureBridgeClient : HostBridgeClient {
    var snapshot: HostSnapshot = HostSnapshot.empty.copy(generation = 1L)
    val dispatchedEvents = java.util.Collections.synchronizedList(mutableListOf<JsonObject>())
    val dispatchedThreads = java.util.Collections.synchronizedList(mutableListOf<Pair<String?, Thread>>())
    val ingestedChunks = mutableListOf<IngestedChunk>()
    var rejectAtSequence: Long? = null
    private var sessionCounter = 0

    override fun apiVersion(): Int = 2
    override fun sessionCreate(directory: String): Long = 900L
    override fun sessionCreateWithCredentials(
        directory: String,
        credentialBridge: KoeNativeBridge.CredentialBridge,
        isolated: Boolean,
    ): Long = 900L
    override fun sessionDestroy(handle: Long): Boolean = true
    override fun sessionGeneration(handle: Long): Long = snapshot.generation

    override fun sessionSnapshotJson(handle: Long, nowEpochSec: Long): String =
        HostJson.json.encodeToString(HostSnapshot.serializer(), snapshot)

    override fun sessionDispatchJson(handle: Long, commandJson: String, nowEpochSec: Long): String {
        val obj = HostJson.json.parseToJsonElement(commandJson) as JsonObject
        dispatchedEvents.add(obj)
        val type = obj["type"]?.jsonPrimitive?.content
        dispatchedThreads.add(type to Thread.currentThread())
        when (type) {
            "start_capture_mode", "start_microphone" -> {
                sessionCounter += 1
                val recordId = "mic-$sessionCounter"
                val sessionId = "$recordId-session"
                val inputId = obj["inputId"]?.jsonPrimitive?.content ?: ""
                val mic = MicrophoneSnapshot(
                    recordId = recordId,
                    sessionId = sessionId,
                    lane = "microphone",
                    inputId = inputId,
                    phase = "starting",
                    nextSequence = 0L,
                    epoch = 0L,
                    clockNs = null,
                    lanes = mapOf("microphone" to CaptureLaneSnapshot(nextSequence = 0L)),
                )
                snapshot = snapshot.copy(
                    generation = snapshot.generation + 1L,
                    error = null,
                    microphone = mic,
                    activeCapture = activeCaptureFor(mic),
                )
            }
            "microphone_prepared" -> {
                val mic = snapshot.microphone
                if (mic != null &&
                    mic.recordId == obj["recordId"]?.jsonPrimitive?.content &&
                    mic.sessionId == obj["sessionId"]?.jsonPrimitive?.content &&
                    mic.epoch == obj["epoch"]?.jsonPrimitive?.long &&
                    mic.phase == "starting"
                ) {
                    val updated = mic.copy(clockNs = obj["clockNs"]?.jsonPrimitive?.long)
                    snapshot = snapshot.copy(
                        generation = snapshot.generation + 1L,
                        microphone = updated,
                        activeCapture = activeCaptureFor(updated),
                    )
                }
            }
            "microphone_started" -> {
                val mic = snapshot.microphone
                val lane = mic?.lanes?.get("microphone")
                if (mic != null && lane != null) {
                    val rate = obj["sampleRate"]?.jsonPrimitive?.int ?: 16_000
                    val updatedLane = lane.copy(
                        sampleRate = lane.sampleRate ?: rate,
                        started = true,
                    )
                    val updated = mic.copy(
                        phase = if (mic.phase == "starting") "recording" else mic.phase,
                        lanes = mapOf("microphone" to updatedLane),
                    )
                    snapshot = snapshot.copy(
                        generation = snapshot.generation + 1L,
                        microphone = updated,
                        activeCapture = activeCaptureFor(updated),
                    )
                }
            }
            "pause_microphone" -> {
                val mic = snapshot.microphone
                if (mic != null && mic.phase == "recording" && mic.clockNs != null) {
                    val updated = mic.copy(phase = "pausing")
                    snapshot = snapshot.copy(
                        generation = snapshot.generation + 1L,
                        microphone = updated,
                        activeCapture = activeCaptureFor(updated),
                    )
                }
            }
            "microphone_paused" -> {
                val mic = snapshot.microphone
                val lane = mic?.lanes?.get("microphone")
                val seq = obj["sequence"]?.jsonPrimitive?.long
                val epoch = obj["epoch"]?.jsonPrimitive?.long
                if (mic != null && lane != null && mic.phase == "pausing" &&
                    seq == lane.nextSequence && epoch == mic.epoch
                ) {
                    val updated = mic.copy(phase = "paused")
                    snapshot = snapshot.copy(
                        generation = snapshot.generation + 1L,
                        microphone = updated,
                        activeCapture = activeCaptureFor(updated),
                    )
                }
            }
            "resume_microphone" -> {
                val mic = snapshot.microphone
                val clockNs = obj["clockNs"]?.jsonPrimitive?.long
                if (mic != null && mic.phase == "paused" && clockNs != null) {
                    val updated = mic.copy(
                        epoch = mic.epoch + 1L,
                        clockNs = clockNs,
                        phase = "recording",
                    )
                    snapshot = snapshot.copy(
                        generation = snapshot.generation + 1L,
                        microphone = updated,
                        activeCapture = activeCaptureFor(updated),
                    )
                }
            }
            "stop_microphone", "cancel_microphone" -> {
                val mic = snapshot.microphone
                if (mic != null) {
                    val updated = mic.copy(
                        phase = if (type == "cancel_microphone") "cancelling" else "stopping",
                    )
                    snapshot = snapshot.copy(
                        generation = snapshot.generation + 1L,
                        microphone = updated,
                        activeCapture = activeCaptureFor(updated),
                    )
                }
            }
            "capture_action" -> {
                val action = obj["action"]?.jsonPrimitive?.content
                val mic = snapshot.microphone
                if (mic != null) {
                    val nextPhase = when (action) {
                        "pause" -> "pausing"
                        "end" -> "stopping"
                        "cancel" -> "cancelling"
                        else -> mic.phase
                    }
                    val updated = mic.copy(phase = nextPhase)
                    snapshot = snapshot.copy(
                        generation = snapshot.generation + 1L,
                        microphone = updated,
                        activeCapture = activeCaptureFor(updated),
                    )
                }
            }
            "microphone_failed" -> {
                val mic = snapshot.microphone
                val lane = mic?.lanes?.get("microphone")
                if (mic != null && lane != null) {
                    val msg = obj["message"]?.jsonPrimitive?.content ?: "failed"
                    val updatedLane = lane.copy(interruption = lane.interruption ?: msg)
                    val updated = mic.copy(
                        phase = if (mic.phase == "cancelling") "cancelling" else "stopping",
                        interruption = msg,
                        lanes = mapOf("microphone" to updatedLane),
                    )
                    snapshot = snapshot.copy(
                        generation = snapshot.generation + 1L,
                        microphone = updated,
                        activeCapture = activeCaptureFor(updated),
                    )
                }
            }
            "microphone_stopped" -> {
                val mic = snapshot.microphone
                val lane = mic?.lanes?.get("microphone")
                val seq = obj["sequence"]?.jsonPrimitive?.long
                if (mic != null && lane != null && seq == lane.nextSequence) {
                    snapshot = snapshot.copy(
                        generation = snapshot.generation + 1L,
                        microphone = null,
                        activeCapture = null,
                    )
                }
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
    ): PcmIngestReceipt {
        val mic = snapshot.microphone ?: return PcmIngestReceipt(snapshot.generation, 0L, PcmIngestStatus.STALE_SESSION)
        val laneState = mic.lanes[lane] ?: return PcmIngestReceipt(snapshot.generation, 0L, PcmIngestStatus.STALE_SESSION)
        if (mic.recordId != recordId || mic.sessionId != sessionId || mic.epoch != epoch) {
            return PcmIngestReceipt(snapshot.generation, laneState.nextSequence, PcmIngestStatus.STALE_SESSION)
        }
        if (rejectAtSequence == sequence || sequence != laneState.nextSequence) {
            snapshot = snapshot.copy(
                generation = snapshot.generation + 1L,
                error = "音频块被拒绝",
            )
            return PcmIngestReceipt(snapshot.generation, laneState.nextSequence, PcmIngestStatus.REJECTED)
        }
        ingestedChunks.add(IngestedChunk(sequence, epoch, capturedStartNs, sampleCount))
        val nextSeq = laneState.nextSequence + 1L
        val updatedLane = laneState.copy(nextSequence = nextSeq)
        val updatedMic = mic.copy(
            nextSequence = nextSeq,
            lanes = mapOf("microphone" to updatedLane),
        )
        snapshot = snapshot.copy(
            generation = snapshot.generation + 1L,
            microphone = updatedMic,
            activeCapture = activeCaptureFor(updatedMic),
        )
        return PcmIngestReceipt(snapshot.generation, nextSeq, PcmIngestStatus.ACCEPTED)
    }

    override fun sessionReportPlaybackProgress(
        handle: Long,
        recordId: String,
        requestId: Long,
        positionMs: Long,
        isPlaying: Boolean,
        lastProjectedNowSec: Long,
        nowEpochSec: Long,
    ): PlaybackProgressReceipt = PlaybackProgressReceipt(
        generation = snapshot.generation,
        prevGeneration = snapshot.generation,
        positionMs = positionMs,
        nowEpochSec = nowEpochSec,
        isPlaying = isPlaying,
        applied = true,
        needsFullSnapshot = false,
    )

    override fun sessionDrainBleTx(handle: Long): ByteArray = ByteArray(0)
    override fun sessionDrainLocalAsr(handle: Long): ByteArray = ByteArray(0)
    override fun sessionPollTimers(handle: Long, elapsedMs: Long, nowEpochSec: Long): Long = snapshot.generation

    private fun activeCaptureFor(mic: MicrophoneSnapshot): ActiveCaptureSnapshot =
        ActiveCaptureSnapshot(
            mode = CaptureMode.QUICK_NOTE,
            phase = mic.phase,
            sourceLabel = "Android 麦克风",
            actions = when (mic.phase) {
                "recording" -> listOf(CaptureAction.PAUSE, CaptureAction.END, CaptureAction.CANCEL)
                "paused" -> listOf(CaptureAction.RESUME, CaptureAction.END, CaptureAction.CANCEL)
                else -> listOf(CaptureAction.END)
            },
        )
}
