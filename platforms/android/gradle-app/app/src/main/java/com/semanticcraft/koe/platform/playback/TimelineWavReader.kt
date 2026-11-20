package com.semanticcraft.koe.platform.playback

import com.semanticcraft.koe.core.PlaybackAssetSnapshot
import com.semanticcraft.koe.core.PlaybackSegmentSnapshot
import java.io.File
import java.io.IOException
import java.io.RandomAccessFile
import java.nio.charset.StandardCharsets

class TimelineWavReader(plan: PlaybackAssetSnapshot) : AutoCloseable {
    private data class WavHeader(
        val channelCount: Int,
        val wavSampleRate: Int,
        val dataOffset: Long,
        val sourceFrames: Long,
    )

    private data class MappedSegment(
        val timelineStartFrame: Long,
        val sourceStartFrame: Long,
        val frameCount: Long,
    ) {
        val timelineEndFrame: Long
            get() = timelineStartFrame + frameCount
    }

    private val raf: RandomAccessFile
    private val dataOffset: Long
    private val frameBytes: Int
    private val segments: List<MappedSegment>
    private val ioBuffer = ByteArray(IO_BUFFER_BYTES)
    private var fileCursor: Long = -1L
    private var segmentCursor: Int = 0
    private var closed: Boolean = false

    val sampleRate: Int
    val channelCount: Int
    val totalFrames: Long
    val durationMs: Long

    var positionFrame: Long = 0L
        private set

    val positionMs: Long
        get() = framesToMs(positionFrame, sampleRate)

    init {
        val file = File(plan.audioPath)
        if (!file.isFile) {
            throw IOException("Audio file does not exist: ${plan.audioPath}")
        }
        val opened = RandomAccessFile(file, "r")
        try {
            val header = parseWavHeader(opened)
            val resolvedRate = plan.sampleRate ?: header.wavSampleRate
            require(resolvedRate > 0) { "Invalid playback sample rate: $resolvedRate" }

            raf = opened
            dataOffset = header.dataOffset
            channelCount = header.channelCount
            frameBytes = header.channelCount * BYTES_PER_SAMPLE
            sampleRate = resolvedRate

            val durationFrames = nsToFrames(plan.durationNs.coerceAtLeast(0L), resolvedRate)
            if (plan.segments.isEmpty()) {
                segments = if (header.sourceFrames > 0L) {
                    listOf(MappedSegment(0L, 0L, header.sourceFrames))
                } else {
                    emptyList()
                }
                totalFrames = maxOf(durationFrames, header.sourceFrames)
            } else {
                val normalized = normalizeSegments(plan.segments, resolvedRate, header.sourceFrames)
                segments = normalized
                val lastEnd = normalized.lastOrNull()?.timelineEndFrame ?: 0L
                totalFrames = maxOf(durationFrames, lastEnd)
            }
            durationMs = framesToMs(totalFrames, resolvedRate)
        } catch (error: Throwable) {
            runCatching { opened.close() }
            throw error
        }
    }

    fun seekToMs(positionMs: Long) {
        val targetFrame = msToFrames(positionMs.coerceAtLeast(0L), sampleRate)
        seekToFrame(targetFrame)
    }

    fun seekToFrame(frame: Long) {
        check(!closed) { "TimelineWavReader is closed" }
        positionFrame = frame.coerceIn(0L, totalFrames)
        segmentCursor = findSegmentIndex(positionFrame)
    }

    fun readFrames(dest: ShortArray, maxFrames: Int): Int {
        check(!closed) { "TimelineWavReader is closed" }
        require(maxFrames >= 0) { "maxFrames must be non-negative: $maxFrames" }
        require(dest.size >= maxFrames * channelCount) {
            "Destination array length ${dest.size} is smaller than ${maxFrames * channelCount}"
        }
        if (maxFrames == 0 || positionFrame >= totalFrames) return 0

        val framesToProduce = minOf(maxFrames.toLong(), totalFrames - positionFrame).toInt()
        var framesWritten = 0

        while (framesWritten < framesToProduce) {
            while (segmentCursor < segments.size && segments[segmentCursor].timelineEndFrame <= positionFrame) {
                segmentCursor += 1
            }
            val remainingRequested = (framesToProduce - framesWritten).toLong()
            val segment = segments.getOrNull(segmentCursor)
            if (segment == null || positionFrame < segment.timelineStartFrame) {
                val silenceEnd = segment?.timelineStartFrame ?: totalFrames
                val silenceFrames = minOf(remainingRequested, silenceEnd - positionFrame).toInt()
                val startShort = framesWritten * channelCount
                dest.fill(0, startShort, startShort + silenceFrames * channelCount)
                framesWritten += silenceFrames
                positionFrame += silenceFrames.toLong()
            } else {
                val offsetInSegment = positionFrame - segment.timelineStartFrame
                val availableInSegment = segment.frameCount - offsetInSegment
                val maxBufferFrames = (ioBuffer.size / frameBytes).coerceAtLeast(1)
                val chunkFrames = minOf(remainingRequested, availableInSegment, maxBufferFrames.toLong()).toInt()
                val byteOffset = dataOffset + (segment.sourceStartFrame + offsetInSegment) * frameBytes
                readSourceFrames(byteOffset, chunkFrames, dest, framesWritten * channelCount)
                framesWritten += chunkFrames
                positionFrame += chunkFrames.toLong()
            }
        }
        return framesWritten
    }

    override fun close() {
        if (closed) return
        closed = true
        raf.close()
    }

    private fun readSourceFrames(byteOffset: Long, frameCount: Int, dest: ShortArray, destShortOffset: Int) {
        val byteCount = frameCount * frameBytes
        if (fileCursor != byteOffset) {
            raf.seek(byteOffset)
            fileCursor = byteOffset
        }
        raf.readFully(ioBuffer, 0, byteCount)
        fileCursor += byteCount.toLong()
        val sampleCount = frameCount * channelCount
        var byteIndex = 0
        for (i in 0 until sampleCount) {
            val lo = ioBuffer[byteIndex].toInt() and 0xFF
            val hi = ioBuffer[byteIndex + 1].toInt() shl 8
            dest[destShortOffset + i] = (lo or hi).toShort()
            byteIndex += 2
        }
    }

    private fun findSegmentIndex(frame: Long): Int {
        var low = 0
        var high = segments.size
        while (low < high) {
            val mid = (low + high) ushr 1
            if (segments[mid].timelineEndFrame <= frame) {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }

    companion object {
        private const val BYTES_PER_SAMPLE = 2
        private const val IO_BUFFER_BYTES = 8192
        private const val NANOS_PER_SECOND = 1_000_000_000L
        private const val MILLIS_PER_SECOND = 1_000L

        internal fun nsToFrames(ns: Long, sampleRate: Int): Long =
            scaleOverflowSafe(ns, sampleRate.toLong(), NANOS_PER_SECOND)

        internal fun msToFrames(ms: Long, sampleRate: Int): Long =
            scaleOverflowSafe(ms, sampleRate.toLong(), MILLIS_PER_SECOND)

        internal fun framesToMs(frames: Long, sampleRate: Int): Long =
            scaleOverflowSafe(frames, MILLIS_PER_SECOND, sampleRate.toLong())

        internal fun framesToNs(frames: Long, sampleRate: Int): Long =
            scaleOverflowSafe(frames, NANOS_PER_SECOND, sampleRate.toLong())

        private fun scaleOverflowSafe(value: Long, numerator: Long, denominator: Long): Long {
            if (value <= 0L) return 0L
            return (value / denominator) * numerator + ((value % denominator) * numerator) / denominator
        }

        private fun normalizeSegments(
            rawSegments: List<PlaybackSegmentSnapshot>,
            sampleRate: Int,
            sourceFrames: Long,
        ): List<MappedSegment> {
            val clipped = rawSegments.mapNotNull { seg ->
                val timelineStart = nsToFrames(seg.timelineStartNs.coerceAtLeast(0L), sampleRate)
                val sourceStart = seg.sourceStartSample.coerceIn(0L, sourceFrames)
                val available = (sourceFrames - sourceStart).coerceAtLeast(0L)
                val count = seg.sampleCount.coerceIn(0L, available)
                if (count > 0L) MappedSegment(timelineStart, sourceStart, count) else null
            }.sortedWith(compareBy<MappedSegment>({ it.timelineStartFrame }, { it.sourceStartFrame }))

            val nonOverlapping = ArrayList<MappedSegment>(clipped.size)
            var cursorEnd = 0L
            for (seg in clipped) {
                if (seg.timelineStartFrame >= cursorEnd) {
                    nonOverlapping.add(seg)
                    cursorEnd = seg.timelineEndFrame
                } else {
                    val overlap = cursorEnd - seg.timelineStartFrame
                    if (overlap < seg.frameCount) {
                        val trimmed = MappedSegment(
                            timelineStartFrame = cursorEnd,
                            sourceStartFrame = seg.sourceStartFrame + overlap,
                            frameCount = seg.frameCount - overlap,
                        )
                        nonOverlapping.add(trimmed)
                        cursorEnd = trimmed.timelineEndFrame
                    }
                }
            }
            return nonOverlapping
        }

        private fun parseWavHeader(raf: RandomAccessFile): WavHeader {
            val fileLength = raf.length()
            if (fileLength < 12L) {
                throw IllegalArgumentException("WAV file too short: $fileLength bytes")
            }
            val riffHeader = ByteArray(12)
            raf.seek(0L)
            raf.readFully(riffHeader)
            val riffId = String(riffHeader, 0, 4, StandardCharsets.US_ASCII)
            val waveId = String(riffHeader, 8, 4, StandardCharsets.US_ASCII)
            if (riffId != "RIFF" || waveId != "WAVE") {
                throw IllegalArgumentException("Unsupported container: expected RIFF/WAVE")
            }
            val riffSize = leU32(riffHeader, 4)
            val riffEnd = 8L + riffSize
            if (riffEnd > fileLength || riffEnd < 12L) {
                throw IOException("Truncated RIFF/WAVE payload: expected $riffEnd bytes, file has $fileLength")
            }

            var channels: Int? = null
            var wavSampleRate: Int? = null
            var dataOffset: Long? = null
            var dataSizeBytes: Long? = null
            val chunkHeader = ByteArray(8)
            var offset = 12L

            while (offset + 8L <= riffEnd) {
                raf.seek(offset)
                raf.readFully(chunkHeader)
                val chunkId = String(chunkHeader, 0, 4, StandardCharsets.US_ASCII)
                val chunkSize = leU32(chunkHeader, 4)
                val chunkDataStart = offset + 8L
                val chunkEnd = chunkDataStart + chunkSize
                if (chunkEnd > riffEnd || chunkEnd < chunkDataStart) {
                    throw IOException("Truncated WAV chunk '$chunkId'")
                }
                when (chunkId) {
                    "fmt " -> {
                        require(chunkSize >= 16L) { "WAV fmt chunk too short: $chunkSize" }
                        val fmt = ByteArray(16)
                        raf.readFully(fmt)
                        val audioFormat = leU16(fmt, 0)
                        val parsedChannels = leU16(fmt, 2)
                        val parsedRate = leU32(fmt, 4)
                        val bitsPerSample = leU16(fmt, 14)
                        require(audioFormat == 1) { "Unsupported WAV audio format: $audioFormat" }
                        require(bitsPerSample == 16) { "Unsupported WAV bit depth: $bitsPerSample" }
                        require(parsedChannels in 1..2) { "Unsupported WAV channel count: $parsedChannels" }
                        require(parsedRate in 1L..Int.MAX_VALUE.toLong()) { "Invalid WAV sample rate: $parsedRate" }
                        channels = parsedChannels
                        wavSampleRate = parsedRate.toInt()
                    }
                    "data" -> {
                        dataOffset = chunkDataStart
                        dataSizeBytes = chunkSize
                    }
                }
                offset = chunkEnd + (chunkSize and 1L)
            }

            val resolvedChannels = requireNotNull(channels) { "WAV missing fmt chunk" }
            val resolvedRate = requireNotNull(wavSampleRate) { "WAV missing fmt chunk" }
            val resolvedDataOffset = requireNotNull(dataOffset) { "WAV missing data chunk" }
            val resolvedDataSize = requireNotNull(dataSizeBytes) { "WAV missing data chunk" }
            val frameBytes = resolvedChannels * BYTES_PER_SAMPLE
            require(resolvedDataSize % frameBytes.toLong() == 0L) {
                "WAV PCM16 data size is not frame-aligned: $resolvedDataSize"
            }
            return WavHeader(
                channelCount = resolvedChannels,
                wavSampleRate = resolvedRate,
                dataOffset = resolvedDataOffset,
                sourceFrames = resolvedDataSize / frameBytes.toLong(),
            )
        }

        private fun leU16(bytes: ByteArray, offset: Int): Int =
            (bytes[offset].toInt() and 0xFF) or ((bytes[offset + 1].toInt() and 0xFF) shl 8)

        private fun leU32(bytes: ByteArray, offset: Int): Long =
            (bytes[offset].toLong() and 0xFFL) or
                ((bytes[offset + 1].toLong() and 0xFFL) shl 8) or
                ((bytes[offset + 2].toLong() and 0xFFL) shl 16) or
                ((bytes[offset + 3].toLong() and 0xFFL) shl 24)
    }
}
