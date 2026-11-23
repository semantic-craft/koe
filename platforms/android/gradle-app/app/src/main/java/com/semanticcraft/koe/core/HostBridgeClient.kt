package com.semanticcraft.koe.core

import com.semanticcraft.koe.bridge.KoeNativeBridge
import java.nio.charset.StandardCharsets

interface HostBridgeClient {
    fun apiVersion(): Int

    fun sessionCreate(directory: String): Long

    fun sessionCreateWithCredentials(
        directory: String,
        credentialBridge: KoeNativeBridge.CredentialBridge,
        isolated: Boolean,
    ): Long

    fun sessionDestroy(handle: Long): Boolean

    fun sessionGeneration(handle: Long): Long

    fun sessionSnapshotJson(handle: Long, nowEpochSec: Long): String?

    fun sessionDispatchJson(handle: Long, commandJson: String, nowEpochSec: Long): String?

    fun sessionIngestBle(handle: Long, bytes: ByteArray, nowEpochSec: Long): Long

    fun sessionIngestPcm(
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
    ): PcmIngestReceipt

    fun sessionReportPlaybackProgress(
        handle: Long,
        recordId: String,
        requestId: Long,
        positionMs: Long,
        isPlaying: Boolean,
        lastProjectedNowSec: Long,
        nowEpochSec: Long,
    ): PlaybackProgressReceipt

    fun sessionDrainBleTx(handle: Long): ByteArray?

    fun sessionDrainLocalAsr(handle: Long): ByteArray?

    fun sessionPollTimers(handle: Long, elapsedMs: Long, nowEpochSec: Long): Long

    fun sessionExportDiagnosticsJson(handle: Long, nowEpochSec: Long): String? = null
}

class JniHostBridgeClient : HostBridgeClient {
    override fun apiVersion(): Int {
        ensureLibrariesLoaded()
        return KoeNativeBridge.nativeApiVersion()
    }

    override fun sessionCreate(directory: String): Long {
        ensureLibrariesLoaded()
        return KoeNativeBridge.nativeSessionCreate(directory.toByteArray(StandardCharsets.UTF_8))
    }

    override fun sessionCreateWithCredentials(
        directory: String,
        credentialBridge: KoeNativeBridge.CredentialBridge,
        isolated: Boolean,
    ): Long {
        ensureLibrariesLoaded()
        return KoeNativeBridge.nativeSessionCreateWithCredentials(
            directory.toByteArray(StandardCharsets.UTF_8),
            credentialBridge,
            isolated,
        )
    }

    override fun sessionDestroy(handle: Long): Boolean {
        ensureLibrariesLoaded()
        return KoeNativeBridge.nativeSessionDestroy(handle)
    }

    override fun sessionGeneration(handle: Long): Long {
        ensureLibrariesLoaded()
        return KoeNativeBridge.nativeSessionGeneration(handle)
    }

    override fun sessionSnapshotJson(handle: Long, nowEpochSec: Long): String? {
        ensureLibrariesLoaded()
        val raw = KoeNativeBridge.nativeSessionSnapshotJson(handle, nowEpochSec) ?: return null
        return String(raw, StandardCharsets.UTF_8)
    }

    override fun sessionDispatchJson(handle: Long, commandJson: String, nowEpochSec: Long): String? {
        ensureLibrariesLoaded()
        val raw = KoeNativeBridge.nativeSessionDispatchJson(
            handle,
            commandJson.toByteArray(StandardCharsets.UTF_8),
            nowEpochSec,
        ) ?: return null
        return String(raw, StandardCharsets.UTF_8)
    }

    override fun sessionIngestBle(handle: Long, bytes: ByteArray, nowEpochSec: Long): Long {
        ensureLibrariesLoaded()
        return KoeNativeBridge.nativeSessionIngestBle(handle, bytes, nowEpochSec)
    }

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
        ensureLibrariesLoaded()
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
        )
        if (raw == null || raw.size < 3) {
            return PcmIngestReceipt(0L, 0L, PcmIngestStatus.REJECTED)
        }
        return PcmIngestReceipt(
            generation = raw[0],
            nextSequence = raw[1],
            status = PcmIngestStatus.fromCode(raw[2].toInt()),
        )
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
        ensureLibrariesLoaded()
        val raw = KoeNativeBridge.nativeSessionReportPlaybackProgress(
            handle,
            recordId.toByteArray(StandardCharsets.UTF_8),
            requestId,
            positionMs,
            isPlaying,
            lastProjectedNowSec,
            nowEpochSec,
        )
        if (raw == null || raw.size < 7) {
            return PlaybackProgressReceipt(0L, 0L, 0L, nowEpochSec, false, false, true)
        }
        return PlaybackProgressReceipt(
            generation = raw[0],
            prevGeneration = raw[1],
            positionMs = raw[2],
            nowEpochSec = raw[3],
            isPlaying = raw[4] != 0L,
            applied = raw[5] != 0L,
            needsFullSnapshot = raw[6] != 0L,
        )
    }

    override fun sessionDrainBleTx(handle: Long): ByteArray? {
        ensureLibrariesLoaded()
        return KoeNativeBridge.nativeSessionDrainBleTx(handle)
    }

    override fun sessionDrainLocalAsr(handle: Long): ByteArray? {
        ensureLibrariesLoaded()
        return KoeNativeBridge.nativeSessionDrainLocalAsr(handle)
    }

    override fun sessionPollTimers(handle: Long, elapsedMs: Long, nowEpochSec: Long): Long {
        ensureLibrariesLoaded()
        return KoeNativeBridge.nativeSessionPollTimers(handle, elapsedMs, nowEpochSec)
    }

    override fun sessionExportDiagnosticsJson(handle: Long, nowEpochSec: Long): String? {
        ensureLibrariesLoaded()
        val raw = KoeNativeBridge.nativeSessionExportDiagnosticsJson(handle, nowEpochSec) ?: return null
        return String(raw, StandardCharsets.UTF_8)
    }

    companion object {
        private val loadLock = Any()

        @Volatile
        private var loaded = false

        fun ensureLibrariesLoaded() {
            if (loaded) return
            synchronized(loadLock) {
                if (loaded) return
                // Explicit dependency order keeps dlopen deterministic on API 29-36.
                KoeNativeBridge.loadLibrary("c++_shared")
                KoeNativeBridge.loadLibrary("koe_host_api")
                KoeNativeBridge.loadLibrary("koe_android")
                loaded = true
            }
        }
    }
}
