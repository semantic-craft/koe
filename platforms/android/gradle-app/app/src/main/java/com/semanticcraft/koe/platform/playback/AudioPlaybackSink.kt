package com.semanticcraft.koe.platform.playback

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.os.Process
import android.os.SystemClock
import com.semanticcraft.koe.core.KoeLogger
import com.semanticcraft.koe.core.PlaybackAssetSnapshot
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

interface AudioPlaybackSink : AutoCloseable {
    val durationMs: Long
    val currentPositionMs: Long
    val isPlaying: Boolean
    val isCompleted: Boolean
    val failureMessage: String?
    fun seekToMs(positionMs: Long)
    fun play()
    fun pause()
    override fun close()
}

fun interface AudioPlaybackSinkFactory {
    fun open(plan: PlaybackAssetSnapshot, onStateChanged: () -> Unit): AudioPlaybackSink
}

class AndroidAudioTrackSink(
    private val reader: TimelineWavReader,
    private val onStateChanged: () -> Unit = {},
) : AudioPlaybackSink {
    private val sampleRate = reader.sampleRate
    private val channelCount = reader.channelCount
    private val totalFrames = reader.totalFrames
    private val chunkFrames = (sampleRate / 25).coerceIn(MIN_CHUNK_FRAMES, MAX_CHUNK_FRAMES)
    private val track: AudioTrack

    private val trackControlLock = Any()
    private val stateLock = Object()

    private var workerThread: Thread? = null
    private var startedEpoch = 0L
    private var epoch = 0L
    private var baseFrame = 0L
    private var pendingSeekFrame: Long? = 0L
    private var writtenFramesSinceBase = 0L
    private var playStartElapsedNs = 0L
    private var headBaseline = -1L
    private var headMoved = false
    private var lastKnownHwDelta = 0L
    private var playingDesired = false
    private var completed = false
    private var closed = false
    private var failure: String? = null
    private val headReadErrorLogged = AtomicBoolean(false)
    private val pendingHeadReadError = AtomicReference<Throwable?>(null)

    override val durationMs: Long = reader.durationMs

    override val currentPositionMs: Long
        get() {
            val pos = synchronized(stateLock) {
                TimelineWavReader.framesToMs(computePositionFrameLocked(SystemClock.elapsedRealtimeNanos()), sampleRate)
            }
            flushPendingHeadReadError()
            return pos
        }

    override val isPlaying: Boolean
        get() = synchronized(stateLock) { playingDesired && !closed && !completed && failure == null }

    override val isCompleted: Boolean
        get() = synchronized(stateLock) { completed }

    override val failureMessage: String?
        get() = synchronized(stateLock) { failure }

    init {
        val channelMask = if (channelCount == 2) AudioFormat.CHANNEL_OUT_STEREO else AudioFormat.CHANNEL_OUT_MONO
        val minBufferBytes = AudioTrack.getMinBufferSize(sampleRate, channelMask, AudioFormat.ENCODING_PCM_16BIT)
        if (minBufferBytes <= 0) {
            reader.close()
            throw IllegalStateException("Unsupported AudioTrack configuration: rate=$sampleRate channels=$channelCount")
        }
        val frameBytes = channelCount * BYTES_PER_SAMPLE
        val bufferBytes = maxOf(minBufferBytes, chunkFrames * frameBytes * 3)
        val created = try {
            val attributes = AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_MEDIA).setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build()
            val format = AudioFormat.Builder()
                .setSampleRate(sampleRate).setEncoding(AudioFormat.ENCODING_PCM_16BIT).setChannelMask(channelMask).build()
            AudioTrack.Builder()
                .setAudioAttributes(attributes).setAudioFormat(format)
                .setBufferSizeInBytes(bufferBytes).setTransferMode(AudioTrack.MODE_STREAM).build()
        } catch (error: Throwable) {
            KoeLogger.e("KoePlayback", "create_track", "AudioTrack init failed", error.javaClass.simpleName, error)
            reader.close()
            throw error
        }
        if (created.state != AudioTrack.STATE_INITIALIZED) {
            KoeLogger.e("KoePlayback", "create_track", "state=${created.state}", "track_not_initialized")
            runCatching { created.release() }.onFailure { KoeLogger.w("KoePlayback", "release_track", "cleanup release failed", error = it) }
            reader.close()
            throw IllegalStateException("AudioTrack failed to initialize")
        }
        track = created
    }

    override fun seekToMs(positionMs: Long) {
        val targetFrame = TimelineWavReader.msToFrames(positionMs.coerceAtLeast(0L), sampleRate)
            .coerceIn(0L, totalFrames)
        val (targetEpoch, wasPlaying) = synchronized(stateLock) {
            if (closed) return
            val active = playingDesired
            baseFrame = targetFrame
            pendingSeekFrame = targetFrame
            resetClockLocked()
            completed = false
            epoch += 1L
            stateLock.notifyAll()
            epoch to active
        }
        if (wasPlaying) {
            interruptTrackBeforeEpoch(targetEpoch)
        }
    }

    override fun play() {
        val threadToStart: Thread?
        var newlyCompleted = false
        synchronized(stateLock) {
            if (closed || failure != null || playingDesired) return
            if (baseFrame >= totalFrames) {
                newlyCompleted = !completed
                completed = true
                threadToStart = null
            } else {
                playingDesired = true
                completed = false
                resetClockLocked()
                epoch += 1L
                threadToStart = if (workerThread == null) {
                    Thread(::runPlaybackLoop, "koe-audio-playback").also { workerThread = it }
                } else {
                    null
                }
                stateLock.notifyAll()
            }
        }
        if (newlyCompleted) {
            onStateChanged()
            return
        }
        threadToStart?.start()
    }

    override fun pause() {
        val targetEpoch = synchronized(stateLock) {
            if (closed || !playingDesired) return
            val frozenFrame = computePositionFrameLocked(SystemClock.elapsedRealtimeNanos())
            baseFrame = frozenFrame
            pendingSeekFrame = frozenFrame
            resetClockLocked()
            playingDesired = false
            epoch += 1L
            stateLock.notifyAll()
            epoch
        }
        flushPendingHeadReadError()
        interruptTrackBeforeEpoch(targetEpoch)
    }

    override fun close() {
        val threadToJoin: Thread?
        synchronized(stateLock) {
            if (closed) return
            baseFrame = computePositionFrameLocked(SystemClock.elapsedRealtimeNanos())
            closed = true
            playingDesired = false
            epoch += 1L
            threadToJoin = workerThread
            workerThread = null
            stateLock.notifyAll()
        }
        flushPendingHeadReadError()
        val (pauseFlushErrs, stopErr) = synchronized(trackControlLock) {
            pauseAndFlushTrackLocked() to captureTrackOp { track.stop() }
        }
        logPauseFlushErrors(pauseFlushErrs)
        logTrackError("stop_track", stopErr)
        if (threadToJoin != null && threadToJoin !== Thread.currentThread()) {
            threadToJoin.interrupt()
            try { threadToJoin.join(CLOSE_JOIN_TIMEOUT_MS) } catch (_: InterruptedException) { Thread.currentThread().interrupt() }
        }
        logTrackError("release_track", synchronized(trackControlLock) { captureTrackOp { track.release() } })
        logTrackError("close_reader", captureTrackOp { reader.close() })
    }

    private fun interruptTrackBeforeEpoch(targetEpoch: Long) {
        val errs = synchronized(trackControlLock) {
            if (startedEpoch >= targetEpoch) return
            pauseAndFlushTrackLocked()
        }
        logPauseFlushErrors(errs)
    }

    private fun pauseAndFlushTrackLocked(): Pair<Throwable?, Throwable?> =
        captureTrackOp { track.pause() } to captureTrackOp { track.flush() }

    private fun logPauseFlushErrors(errs: Pair<Throwable?, Throwable?>) {
        logTrackError("pause_track", errs.first)
        logTrackError("flush_track", errs.second)
    }

    private inline fun captureTrackOp(block: () -> Unit): Throwable? = try {
        block(); null
    } catch (error: Throwable) { error }

    private fun logTrackError(operation: String, error: Throwable?) {
        if (error != null) KoeLogger.w("KoePlayback", operation, "AudioTrack op failed", error.javaClass.simpleName, error)
    }

    private fun resetClockLocked() {
        writtenFramesSinceBase = 0L
        playStartElapsedNs = 0L
        headBaseline = -1L
        headMoved = false
        lastKnownHwDelta = 0L
    }

    private fun runPlaybackLoop() {
        Process.setThreadPriority(Process.THREAD_PRIORITY_AUDIO)
        val pcmBuffer = ShortArray(chunkFrames * channelCount)

        while (true) {
            val (localEpoch, seekFrame) = synchronized(stateLock) {
                while (!closed && !playingDesired) {
                    try {
                        stateLock.wait()
                    } catch (_: InterruptedException) {
                        if (closed) return
                    }
                }
                if (closed) return
                val targetSeek = pendingSeekFrame
                pendingSeekFrame = null
                epoch to targetSeek
            }

            if (seekFrame != null) {
                try {
                    reader.seekToFrame(seekFrame)
                } catch (error: Throwable) {
                    recordFailure(localEpoch, error)
                    continue
                }
            }

            val startedBaseline = startTrackForEpoch(localEpoch) ?: continue
            val stillActive = synchronized(stateLock) {
                if (closed || !playingDesired || epoch != localEpoch) {
                    false
                } else {
                    resetClockLocked()
                    headBaseline = startedBaseline
                    playStartElapsedNs = SystemClock.elapsedRealtimeNanos()
                    true
                }
            }
            if (!stillActive) continue

            streamEpoch(localEpoch, pcmBuffer)
        }
    }

    private fun startTrackForEpoch(localEpoch: Long): Long? {
        var failureError: Throwable? = null
        var pauseFlushErrs: Pair<Throwable?, Throwable?>? = null
        val baseline = synchronized(trackControlLock) {
            val active = synchronized(stateLock) { !closed && playingDesired && epoch == localEpoch }
            if (!active) return null
            try {
                pauseFlushErrs = pauseAndFlushTrackLocked()
                val head = readPlaybackHeadFrames() ?: 0L
                track.play()
                startedEpoch = localEpoch
                head
            } catch (error: Throwable) {
                failureError = error
                null
            }
        }
        pauseFlushErrs?.let(::logPauseFlushErrors)
        flushPendingHeadReadError()
        val error = failureError
        if (error != null) {
            recordFailure(localEpoch, error)
            return null
        }
        return baseline
    }

    private fun streamEpoch(localEpoch: Long, pcmBuffer: ShortArray) {
        while (true) {
            val active = synchronized(stateLock) { !closed && playingDesired && epoch == localEpoch }
            if (!active) return

            val framesRead = try {
                reader.readFrames(pcmBuffer, chunkFrames)
            } catch (error: Throwable) {
                recordFailure(localEpoch, error)
                return
            }

            if (framesRead == 0) {
                drainToCompletion(localEpoch)
                return
            }

            if (!writeChunk(localEpoch, pcmBuffer, framesRead * channelCount)) return
            paceIfAhead(localEpoch)
        }
    }

    private fun writeChunk(localEpoch: Long, pcmBuffer: ShortArray, totalShorts: Int): Boolean {
        var offset = 0
        while (offset < totalShorts) {
            val active = synchronized(stateLock) { !closed && playingDesired && epoch == localEpoch }
            if (!active) return false
            val written = try {
                track.write(pcmBuffer, offset, totalShorts - offset, AudioTrack.WRITE_BLOCKING)
            } catch (error: Throwable) {
                recordFailure(localEpoch, error)
                return false
            }
            if (written < 0) {
                recordFailure(localEpoch, IllegalStateException("AudioTrack write error: $written"))
                return false
            }
            if (written == 0) return false
            offset += written
            val framesWritten = (written / channelCount).toLong()
            synchronized(stateLock) {
                if (epoch == localEpoch) {
                    writtenFramesSinceBase += framesWritten
                }
            }
        }
        return true
    }

    private fun paceIfAhead(localEpoch: Long) {
        synchronized(stateLock) {
            if (closed || !playingDesired || epoch != localEpoch || playStartElapsedNs == 0L) return
            val nowNs = SystemClock.elapsedRealtimeNanos()
            updateHardwareHeadLocked()
            val writtenNs = TimelineWavReader.framesToNs(writtenFramesSinceBase, sampleRate)
            val elapsedNs = (nowNs - playStartElapsedNs).coerceAtLeast(0L)
            val aheadMs = (writtenNs - elapsedNs) / 1_000_000L
            val thresholdMs = if (headMoved) HW_PACE_AHEAD_MS else STUB_PACE_AHEAD_MS
            if (aheadMs > thresholdMs) {
                val waitMs = (aheadMs - thresholdMs).coerceIn(1L, MAX_PACE_WAIT_MS)
                try {
                    stateLock.wait(waitMs)
                } catch (_: InterruptedException) {
                }
            }
        }
        flushPendingHeadReadError()
    }

    private fun drainToCompletion(localEpoch: Long) {
        val stopErr = synchronized(trackControlLock) {
            val active = synchronized(stateLock) { !closed && playingDesired && epoch == localEpoch }
            if (!active) return
            captureTrackOp { track.stop() }
        }
        logTrackError("drain_stop_track", stopErr)
        val didComplete = synchronized(stateLock) {
            var reachedEnd = false
            while (!closed && playingDesired && epoch == localEpoch) {
                val written = writtenFramesSinceBase
                if (written <= 0L) {
                    reachedEnd = finishCompletedLocked()
                    break
                }
                val nowNs = SystemClock.elapsedRealtimeNanos()
                val playedDelta = computeDeltaFramesLocked(nowNs)
                val elapsedNs = (nowNs - playStartElapsedNs).coerceAtLeast(0L)
                val expectedNs = TimelineWavReader.framesToNs(written, sampleRate)
                val drained = playedDelta >= written ||
                    (headMoved && elapsedNs >= expectedNs + DRAIN_GRACE_NS)
                if (drained) {
                    reachedEnd = finishCompletedLocked()
                    break
                }
                try {
                    stateLock.wait(DRAIN_POLL_MS)
                } catch (_: InterruptedException) {
                    break
                }
            }
            reachedEnd
        }
        flushPendingHeadReadError()
        if (didComplete) onStateChanged()
    }

    private fun finishCompletedLocked(): Boolean {
        val newlyCompleted = !completed
        baseFrame = totalFrames
        pendingSeekFrame = totalFrames
        resetClockLocked()
        playingDesired = false
        completed = true
        return newlyCompleted
    }

    private fun recordFailure(localEpoch: Long, error: Throwable) {
        val shouldNotify = synchronized(stateLock) {
            if (closed || epoch != localEpoch || !playingDesired || failure != null) return
            failure = error.message?.takeIf { it.isNotBlank() } ?: error.javaClass.simpleName
            playingDesired = false
            stateLock.notifyAll()
            true
        }
        if (shouldNotify) {
            KoeLogger.e("KoePlayback", "playback_failed", "AudioTrack playback failed", error.javaClass.simpleName, error)
            onStateChanged()
        }
    }

    private fun updateHardwareHeadLocked(): Long? {
        if (closed || headBaseline < 0L) return null
        val rawHead = readPlaybackHeadFrames() ?: return null
        val delta = (rawHead - headBaseline) and 0xFFFF_FFFFL
        if (delta > writtenFramesSinceBase) return null
        if (delta > 0L) {
            headMoved = true
            lastKnownHwDelta = delta
        }
        return delta
    }

    private fun computeDeltaFramesLocked(nowNs: Long): Long {
        val hwDelta = updateHardwareHeadLocked()
        if (headMoved) {
            return (hwDelta ?: lastKnownHwDelta).coerceIn(0L, writtenFramesSinceBase)
        }
        val elapsedNs = (nowNs - playStartElapsedNs).coerceAtLeast(0L)
        if (elapsedNs < STUB_HAL_FALLBACK_NS) return 0L
        return TimelineWavReader.nsToFrames(elapsedNs, sampleRate).coerceIn(0L, writtenFramesSinceBase)
    }

    private fun computePositionFrameLocked(nowNs: Long): Long {
        if (completed) return totalFrames
        if (closed || !playingDesired || playStartElapsedNs == 0L) {
            return baseFrame.coerceIn(0L, totalFrames)
        }
        val delta = computeDeltaFramesLocked(nowNs)
        val upperBound = (baseFrame + writtenFramesSinceBase).coerceAtMost(totalFrames)
        return (baseFrame + delta).coerceIn(baseFrame, upperBound)
    }

    private fun readPlaybackHeadFrames(): Long? = try {
        track.playbackHeadPosition.toLong() and 0xFFFF_FFFFL
    } catch (error: Throwable) {
        if (headReadErrorLogged.compareAndSet(false, true)) pendingHeadReadError.set(error)
        null
    }

    private fun flushPendingHeadReadError() {
        val error = pendingHeadReadError.getAndSet(null) ?: return
        KoeLogger.w("KoePlayback", "read_head_position", "getPlaybackHeadPosition failed", error.javaClass.simpleName, error)
    }

    companion object {
        private const val BYTES_PER_SAMPLE = 2
        private const val MIN_CHUNK_FRAMES = 256
        private const val MAX_CHUNK_FRAMES = 2048
        private const val STUB_PACE_AHEAD_MS = 20L
        private const val HW_PACE_AHEAD_MS = 120L
        private const val MAX_PACE_WAIT_MS = 40L
        private const val STUB_HAL_FALLBACK_NS = 120_000_000L
        private const val DRAIN_GRACE_NS = 250_000_000L
        private const val DRAIN_POLL_MS = 20L
        private const val CLOSE_JOIN_TIMEOUT_MS = 2_000L

        val Factory: AudioPlaybackSinkFactory = AudioPlaybackSinkFactory { plan, onStateChanged ->
            AndroidAudioTrackSink(TimelineWavReader(plan), onStateChanged)
        }
    }
}
