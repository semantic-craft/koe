package com.semanticcraft.koe.platform.capture

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.media.AudioDeviceInfo
import android.media.AudioFocusRequest
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.AudioTimestamp
import android.media.MediaRecorder
import android.os.Process
import android.os.SystemClock
import com.semanticcraft.koe.core.KoeLogger
import java.util.concurrent.atomic.AtomicBoolean

class AndroidAudioRecordSource(
    private val context: Context,
    private val permissionCoordinator: AndroidPermissionCoordinator,
) : AndroidMicrophoneSource {
    private val lifecycleLock = Any()
    private var activeRecord: AudioRecord? = null
    private var activeStopFlag: AtomicBoolean? = null
    private var activeThread: Thread? = null

    override fun requestPermission(onResult: (Boolean) -> Unit) {
        permissionCoordinator.requestRecordAudio(onResult)
    }

    override fun start(
        inputId: String,
        expectedSampleRate: Int?,
        onChunk: (CapturedPcm) -> Unit,
        onFailure: (String) -> Unit,
    ): Int {
        stop()
        if (context.checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            throw SecurityException("未获得麦克风权限")
        }
        val sampleRate = expectedSampleRate ?: DEFAULT_SAMPLE_RATE
        if (sampleRate !in MIN_SAMPLE_RATE..MAX_SAMPLE_RATE) {
            throw IllegalArgumentException("音频采样率不受支持：$sampleRate")
        }
        val minBufferBytes = AudioRecord.getMinBufferSize(
            sampleRate,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT,
        )
        if (minBufferBytes <= 0) {
            throw IllegalStateException("设备不支持 ${sampleRate} Hz 单声道录音。")
        }
        val chunkSamples = (sampleRate / 16).coerceIn(MIN_CHUNK_SAMPLES, MAX_CHUNK_SAMPLES)
        val bufferBytes = maxOf(minBufferBytes * 2, chunkSamples * BYTES_PER_SAMPLE * 4)
        val record = createAudioRecord(sampleRate, bufferBytes)
            ?: throw IllegalStateException("无法初始化麦克风录音设备。")

        if (inputId.isNotBlank()) {
            findPreferredInputDevice(inputId)?.let { device ->
                record.setPreferredDevice(device)
            }
        }

        val startClockNs = SystemClock.elapsedRealtimeNanos()
        try {
            record.startRecording()
        } catch (error: Throwable) {
            KoeLogger.e("KoeCapture", "start_recording", "AudioRecord.startRecording failed", error.javaClass.simpleName, error)
            releaseSafely(record, "start_recording_rollback")
            throw error
        }
        if (record.recordingState != AudioRecord.RECORDSTATE_RECORDING) {
            KoeLogger.e("KoeCapture", "start_recording", "recordingState=${record.recordingState}", "record_not_recording")
            releaseSafely(record, "start_recording_state_rollback")
            throw IllegalStateException("无法启动麦克风录音。")
        }

        val stopFlag = AtomicBoolean(false)
        val readerThread = Thread(
            {
                runReaderLoop(
                    record = record,
                    sampleRate = sampleRate,
                    chunkSamples = chunkSamples,
                    startClockNs = startClockNs,
                    stopFlag = stopFlag,
                    onChunk = onChunk,
                    onFailure = onFailure,
                )
            },
            "koe-audio-record",
        )
        synchronized(lifecycleLock) {
            activeRecord = record
            activeStopFlag = stopFlag
            activeThread = readerThread
        }
        readerThread.start()
        return sampleRate
    }

    override fun stop() {
        val record: AudioRecord?
        val stopFlag: AtomicBoolean?
        val thread: Thread?
        synchronized(lifecycleLock) {
            record = activeRecord
            stopFlag = activeStopFlag
            thread = activeThread
            activeRecord = null
            activeStopFlag = null
            activeThread = null
        }
        if (record == null && thread == null) return
        stopFlag?.set(true)
        try {
            record?.stop()
        } catch (error: IllegalStateException) {
            KoeLogger.w("KoeCapture", "stop_recording", "AudioRecord.stop failed", "illegal_state", error)
        }
        thread?.interrupt()
        if (thread != null && thread !== Thread.currentThread()) {
            try {
                thread.join(STOP_JOIN_TIMEOUT_MS)
            } catch (_: InterruptedException) {
                Thread.currentThread().interrupt()
            }
        }
        if (record != null) {
            releaseSafely(record, "stop_release")
        }
    }

    private fun releaseSafely(record: AudioRecord, operation: String) {
        try {
            record.release()
        } catch (error: Throwable) {
            KoeLogger.w("KoeCapture", operation, "AudioRecord.release failed", error.javaClass.simpleName, error)
        }
    }

    private fun createAudioRecord(sampleRate: Int, bufferBytes: Int): AudioRecord? {
        val format = AudioFormat.Builder()
            .setSampleRate(sampleRate)
            .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
            .setChannelMask(AudioFormat.CHANNEL_IN_MONO)
            .build()
        for (source in AUDIO_SOURCE_FALLBACKS) {
            val candidate = try {
                AudioRecord.Builder()
                    .setAudioSource(source)
                    .setAudioFormat(format)
                    .setBufferSizeInBytes(bufferBytes)
                    .build()
            } catch (error: Throwable) {
                KoeLogger.w("KoeCapture", "create_audio_record", "source=$source build failed", error.javaClass.simpleName, error)
                null
            } ?: continue
            if (candidate.state == AudioRecord.STATE_INITIALIZED) {
                return candidate
            }
            KoeLogger.w("KoeCapture", "create_audio_record", "source=$source state=${candidate.state}", "not_initialized")
            releaseSafely(candidate, "create_audio_record_cleanup")
        }
        return null
    }

    private fun findPreferredInputDevice(inputId: String): AudioDeviceInfo? {
        val manager = context.getSystemService(AudioManager::class.java) ?: return null
        return manager.getDevices(AudioManager.GET_DEVICES_INPUTS)
            .firstOrNull { it.id.toString() == inputId }
    }

    private fun runReaderLoop(
        record: AudioRecord,
        sampleRate: Int,
        chunkSamples: Int,
        startClockNs: Long,
        stopFlag: AtomicBoolean,
        onChunk: (CapturedPcm) -> Unit,
        onFailure: (String) -> Unit,
    ) {
        Process.setThreadPriority(Process.THREAD_PRIORITY_AUDIO)
        val buffer = ShortArray(chunkSamples)
        val timestamp = AudioTimestamp()
        var totalFramesRead = 0L
        var minNextStartNs = startClockNs
        var timestampErrorLogged = false

        while (!stopFlag.get()) {
            val readCount = try {
                record.read(buffer, 0, buffer.size, AudioRecord.READ_BLOCKING)
            } catch (error: Throwable) {
                if (!stopFlag.get()) {
                    KoeLogger.e("KoeCapture", "read_audio", "AudioRecord.read threw", error.javaClass.simpleName, error)
                    onFailure("麦克风读取失败：${error.message ?: "未知错误"}")
                }
                break
            }
            if (readCount > 0) {
                val nowNs = SystemClock.elapsedRealtimeNanos()
                val chunkDurationNs = (readCount.toLong() * NANOS_PER_SECOND) / sampleRate.toLong()
                val candidateStartNs = resolveChunkTimestampNs(
                    record = record,
                    timestamp = timestamp,
                    totalFramesRead = totalFramesRead,
                    sampleRate = sampleRate,
                    startClockNs = startClockNs,
                    nowNs = nowNs,
                    chunkDurationNs = chunkDurationNs,
                    onTimestampError = { err ->
                        if (!timestampErrorLogged) {
                            timestampErrorLogged = true
                            KoeLogger.w("KoeCapture", "audio_timestamp", "getTimestamp unsupported", err.javaClass.simpleName, err)
                        }
                    },
                )
                val capturedStartNs = maxOf(candidateStartNs, minNextStartNs)
                minNextStartNs = capturedStartNs + chunkDurationNs
                totalFramesRead += readCount.toLong()
                onChunk(CapturedPcm(buffer.copyOf(readCount), capturedStartNs))

                val aheadMs = (minNextStartNs - SystemClock.elapsedRealtimeNanos()) / 1_000_000L
                if (aheadMs > PACE_TOLERANCE_MS && !stopFlag.get()) {
                    try {
                        Thread.sleep(aheadMs.coerceAtMost(MAX_PACE_SLEEP_MS))
                    } catch (_: InterruptedException) {
                        if (stopFlag.get()) break
                    }
                }
            } else if (readCount < 0) {
                if (!stopFlag.get()) {
                    KoeLogger.e("KoeCapture", "read_audio", "AudioRecord.read code=$readCount", "audio_read_$readCount")
                    onFailure("麦克风读取失败（错误码 $readCount）。")
                }
                break
            }
        }
    }

    private fun resolveChunkTimestampNs(
        record: AudioRecord,
        timestamp: AudioTimestamp,
        totalFramesRead: Long,
        sampleRate: Int,
        startClockNs: Long,
        nowNs: Long,
        chunkDurationNs: Long,
        onTimestampError: (Throwable) -> Unit,
    ): Long {
        val status = try {
            record.getTimestamp(timestamp, AudioTimestamp.TIMEBASE_BOOTTIME)
        } catch (error: Throwable) {
            onTimestampError(error)
            AudioRecord.ERROR_INVALID_OPERATION
        }
        if (status == AudioRecord.SUCCESS && timestamp.nanoTime > 0L) {
            val frameDelta = totalFramesRead - timestamp.framePosition
            val candidate = timestamp.nanoTime + (frameDelta * NANOS_PER_SECOND) / sampleRate.toLong()
            if (candidate >= startClockNs - TIMESTAMP_DRIFT_GUARD_NS &&
                candidate <= nowNs + TIMESTAMP_DRIFT_GUARD_NS
            ) {
                return candidate
            }
        }
        return nowNs - chunkDurationNs
    }

    companion object {
        const val DEFAULT_SAMPLE_RATE = 16_000
        private const val MIN_SAMPLE_RATE = 8_000
        private const val MAX_SAMPLE_RATE = 96_000
        private const val MIN_CHUNK_SAMPLES = 1024
        private const val MAX_CHUNK_SAMPLES = 4096
        private const val BYTES_PER_SAMPLE = 2
        private const val NANOS_PER_SECOND = 1_000_000_000L
        private const val TIMESTAMP_DRIFT_GUARD_NS = 1_000_000_000L
        private const val STOP_JOIN_TIMEOUT_MS = 2_000L
        private const val PACE_TOLERANCE_MS = 5L
        private const val MAX_PACE_SLEEP_MS = 64L
        private val AUDIO_SOURCE_FALLBACKS = intArrayOf(
            MediaRecorder.AudioSource.VOICE_RECOGNITION,
            MediaRecorder.AudioSource.MIC,
        )
    }
}

class SystemAudioFocusController(
    context: Context,
) : AudioFocusController {
    private val audioManager = context.getSystemService(AudioManager::class.java)
    private val lock = Any()
    private var activeRequest: AudioFocusRequest? = null

    override fun requestFocus(onFocusLost: () -> Unit): Boolean {
        val manager = audioManager ?: return true
        abandonFocus()
        val attributes = AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_MEDIA)
            .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
            .build()
        val request = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
            .setAudioAttributes(attributes)
            .setAcceptsDelayedFocusGain(false)
            .setOnAudioFocusChangeListener { focusChange ->
                if (focusChange == AudioManager.AUDIOFOCUS_LOSS ||
                    focusChange == AudioManager.AUDIOFOCUS_LOSS_TRANSIENT
                ) {
                    onFocusLost()
                }
            }
            .build()
        val granted = manager.requestAudioFocus(request) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
        if (granted) {
            synchronized(lock) { activeRequest = request }
        }
        return granted
    }

    override fun abandonFocus() {
        val previous = synchronized(lock) {
            val req = activeRequest
            activeRequest = null
            req
        } ?: return
        audioManager?.abandonAudioFocusRequest(previous)
    }
}
