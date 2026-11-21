package com.semanticcraft.koe.platform.capture

import com.semanticcraft.koe.core.MicrophoneSnapshot

data class CapturedPcm(
    val samples: ShortArray,
    val capturedStartNs: Long,
) {
    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is CapturedPcm) return false
        return capturedStartNs == other.capturedStartNs && samples.contentEquals(other.samples)
    }

    override fun hashCode(): Int = 31 * samples.contentHashCode() + capturedStartNs.hashCode()
}

data class CaptureSession(
    val recordId: String,
    val sessionId: String,
    val epoch: Long,
) {
    companion object {
        fun from(snapshot: MicrophoneSnapshot): CaptureSession =
            CaptureSession(
                recordId = snapshot.recordId,
                sessionId = snapshot.sessionId,
                epoch = snapshot.epoch,
            )
    }
}

data class CaptureIdentity(
    val recordId: String,
    val sessionId: String,
    val lane: String,
    val epoch: Long,
) {
    companion object {
        fun from(snapshot: MicrophoneSnapshot, lane: String): CaptureIdentity =
            CaptureIdentity(
                recordId = snapshot.recordId,
                sessionId = snapshot.sessionId,
                lane = lane,
                epoch = snapshot.epoch,
            )
    }
}

interface AndroidMicrophoneSource {
    fun requestPermission(onResult: (Boolean) -> Unit)

    fun start(
        inputId: String,
        expectedSampleRate: Int?,
        onChunk: (CapturedPcm) -> Unit,
        onFailure: (String) -> Unit,
    ): Int

    fun stop()
}

interface AudioFocusController {
    fun requestFocus(onFocusLost: () -> Unit): Boolean

    fun abandonFocus()
}

data class CaptureForegroundState(
    val active: Boolean,
    val paused: Boolean,
    val modeTitle: String? = null,
    val beanCapture: Boolean = false,
)

class MicrophoneMailbox(
    nextSequence: Long,
    val limit: Int = 64,
) {
    data class Block(
        val sequence: Long,
        val pcm: CapturedPcm,
    )

    private val lock = Any()
    private val ring = arrayOfNulls<Block>(limit.coerceAtLeast(1))
    private var head = 0
    private var count = 0
    private var sequence = nextSequence
    private var closed = false
    private var failure: String? = null

    fun append(pcm: CapturedPcm) {
        synchronized(lock) {
            if (closed) return
            if (pcm.samples.isEmpty() || pcm.samples.size > MAX_CHUNK_SAMPLES || count >= limit) {
                failure = OVERFLOW_MESSAGE
                closed = true
                return
            }
            val tail = (head + count) % ring.size
            ring[tail] = Block(sequence = sequence, pcm = pcm)
            count += 1
            sequence += 1L
        }
    }

    fun fail(message: String) {
        synchronized(lock) {
            if (failure == null) {
                failure = message
            }
            closed = true
        }
    }

    fun close() {
        synchronized(lock) {
            closed = true
        }
    }

    fun discardUnaccepted(nextSequence: Long) {
        synchronized(lock) {
            closed = true
            for (offset in 0 until count) {
                ring[(head + offset) % ring.size] = null
            }
            head = 0
            count = 0
            sequence = nextSequence
        }
    }

    fun peek(): Block? = synchronized(lock) {
        if (count > 0) ring[head] else null
    }

    fun acknowledge(sequence: Long) {
        synchronized(lock) {
            if (count > 0 && ring[head]?.sequence == sequence) {
                ring[head] = null
                head = (head + 1) % ring.size
                count -= 1
            }
        }
    }

    val error: String?
        get() = synchronized(lock) { failure }

    val finalSequence: Long
        get() = synchronized(lock) { sequence }

    companion object {
        const val MAX_CHUNK_SAMPLES = 8192
        const val OVERFLOW_MESSAGE = "音频处理未能跟上采集，已停止并保留已接收的音频。"
    }
}
