package com.semanticcraft.koe.platform.playback

import com.semanticcraft.koe.core.PlaybackAssetSnapshot
import com.semanticcraft.koe.core.PlaybackSegmentSnapshot
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.IOException
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.charset.StandardCharsets
import java.nio.file.Files
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class TimelineWavReaderTest {
    private fun withTempDir(block: (File) -> Unit) {
        val dir = Files.createTempDirectory("koe-wav-reader-test").toFile()
        try {
            block(dir)
        } finally {
            dir.deleteRecursively()
        }
    }

    private fun writeWav(
        file: File,
        sampleRate: Int,
        channels: Int,
        samples: ShortArray,
        audioFormat: Int = 1,
        bitsPerSample: Int = 16,
        preFmtChunks: List<Pair<String, ByteArray>> = emptyList(),
        betweenFmtAndDataChunks: List<Pair<String, ByteArray>> = emptyList(),
        declaredDataSizeOverride: Int? = null,
    ) {
        val body = ByteArrayOutputStream()
        body.write("WAVE".toByteArray(StandardCharsets.US_ASCII))

        fun writeChunk(id: String, payload: ByteArray, sizeOverride: Int? = null) {
            body.write(id.toByteArray(StandardCharsets.US_ASCII))
            body.write(le32(sizeOverride ?: payload.size))
            body.write(payload)
            if (payload.size % 2 != 0) body.write(0)
        }

        preFmtChunks.forEach { (id, payload) -> writeChunk(id, payload) }

        val fmt = ByteBuffer.allocate(16).order(ByteOrder.LITTLE_ENDIAN)
        val byteRate = sampleRate * channels * (bitsPerSample / 8)
        val blockAlign = channels * (bitsPerSample / 8)
        fmt.putShort(audioFormat.toShort())
        fmt.putShort(channels.toShort())
        fmt.putInt(sampleRate)
        fmt.putInt(byteRate)
        fmt.putShort(blockAlign.toShort())
        fmt.putShort(bitsPerSample.toShort())
        writeChunk("fmt ", fmt.array())

        betweenFmtAndDataChunks.forEach { (id, payload) -> writeChunk(id, payload) }

        val pcm = ByteBuffer.allocate(samples.size * 2).order(ByteOrder.LITTLE_ENDIAN)
        samples.forEach { pcm.putShort(it) }
        writeChunk("data", pcm.array(), sizeOverride = declaredDataSizeOverride)

        val bodyBytes = body.toByteArray()
        val riff = ByteArrayOutputStream()
        riff.write("RIFF".toByteArray(StandardCharsets.US_ASCII))
        riff.write(le32(bodyBytes.size))
        riff.write(bodyBytes)
        file.writeBytes(riff.toByteArray())
    }

    private fun le32(value: Int): ByteArray =
        ByteBuffer.allocate(4).order(ByteOrder.LITTLE_ENDIAN).putInt(value).array()

    @Test
    fun continuousMonoWavReadsAcrossExtraChunksSeeksAccuratelyAndStopsAtEof() = withTempDir { dir ->
        val wavFile = File(dir, "mono.wav")
        val sourceSamples = ShortArray(1600) { idx -> ((idx * 17) - 10_000).toShort() }
        writeWav(
            file = wavFile,
            sampleRate = 16_000,
            channels = 1,
            samples = sourceSamples,
            preFmtChunks = listOf("JUNK" to byteArrayOf(1, 2, 3, 4)),
            betweenFmtAndDataChunks = listOf("LIST" to byteArrayOf(9, 8, 7, 6, 5)),
        )

        val plan = PlaybackAssetSnapshot(
            audioPath = wavFile.absolutePath,
            sampleRate = null,
            durationNs = 0L,
            segments = emptyList(),
        )
        TimelineWavReader(plan).use { reader ->
            assertEquals(16_000, reader.sampleRate)
            assertEquals(1, reader.channelCount)
            assertEquals(1600L, reader.totalFrames)
            assertEquals(100L, reader.durationMs)
            assertEquals(0L, reader.positionFrame)
            assertEquals(0L, reader.positionMs)

            val collected = ShortArray(1600)
            val chunk = ShortArray(300)
            var offset = 0
            while (true) {
                val read = reader.readFrames(chunk, 300)
                if (read == 0) break
                chunk.copyInto(collected, destinationOffset = offset, startIndex = 0, endIndex = read)
                offset += read
            }
            assertEquals(1600, offset)
            assertArrayEquals(sourceSamples, collected)
            assertEquals(1600L, reader.positionFrame)
            assertEquals(100L, reader.positionMs)
            assertEquals(0, reader.readFrames(chunk, 300))

            reader.seekToMs(50L)
            assertEquals(800L, reader.positionFrame)
            assertEquals(50L, reader.positionMs)
            val slice = ShortArray(100)
            assertEquals(100, reader.readFrames(slice, 100))
            assertArrayEquals(sourceSamples.copyOfRange(800, 900), slice)

            reader.seekToMs(500L)
            assertEquals(1600L, reader.positionFrame)
            assertEquals(0, reader.readFrames(slice, 100))

            reader.seekToMs(0L)
            val head = ShortArray(16)
            assertEquals(16, reader.readFrames(head, 16))
            assertArrayEquals(sourceSamples.copyOfRange(0, 16), head)
        }
    }

    @Test
    fun stereoWavPreservesInterleavedChannelsAndPadsTrailingDurationSilence() = withTempDir { dir ->
        val wavFile = File(dir, "stereo.wav")
        val sourceFrames = 480
        val interleaved = ShortArray(sourceFrames * 2) { idx ->
            val frame = idx / 2
            if (idx % 2 == 0) (1000 + frame).toShort() else (-2000 - frame).toShort()
        }
        writeWav(
            file = wavFile,
            sampleRate = 48_000,
            channels = 2,
            samples = interleaved,
        )

        val plan = PlaybackAssetSnapshot(
            audioPath = wavFile.absolutePath,
            sampleRate = 48_000,
            durationNs = 25_000_000L,
            segments = emptyList(),
        )
        TimelineWavReader(plan).use { reader ->
            assertEquals(48_000, reader.sampleRate)
            assertEquals(2, reader.channelCount)
            assertEquals(1200L, reader.totalFrames)
            assertEquals(25L, reader.durationMs)

            val all = ShortArray(1200 * 2)
            assertEquals(1200, reader.readFrames(all, 1200))
            assertArrayEquals(interleaved, all.copyOfRange(0, 480 * 2))
            assertArrayEquals(ShortArray((1200 - 480) * 2), all.copyOfRange(480 * 2, 1200 * 2))
            assertEquals(0, reader.readFrames(all, 16))

            reader.seekToMs(5L)
            assertEquals(240L, reader.positionFrame)
            val mid = ShortArray(4)
            assertEquals(2, reader.readFrames(mid, 2))
            assertArrayEquals(shortArrayOf(1240, -2240, 1241, -2241), mid)

            reader.seekToMs(15L)
            assertEquals(720L, reader.positionFrame)
            val tail = ShortArray(480 * 2)
            assertEquals(480, reader.readFrames(tail, 480))
            assertTrue(tail.all { it == 0.toShort() })
            assertEquals(0, reader.readFrames(tail, 10))
        }
    }

    @Test
    fun multiSegmentSparseTimelineFillsLeadingInterSegmentAndTrailingSilence() = withTempDir { dir ->
        val wavFile = File(dir, "sparse.wav")
        val samples = ShortArray(320) { idx -> if (idx < 160) 8192 else 16384 }
        writeWav(
            file = wavFile,
            sampleRate = 16_000,
            channels = 1,
            samples = samples,
        )

        val plan = PlaybackAssetSnapshot(
            audioPath = wavFile.absolutePath,
            sampleRate = 16_000,
            durationNs = 150_000_000L,
            segments = listOf(
                PlaybackSegmentSnapshot(
                    sourceStartSample = 160L,
                    sampleCount = 160L,
                    timelineStartNs = 100_000_000L,
                ),
                PlaybackSegmentSnapshot(
                    sourceStartSample = 0L,
                    sampleCount = 160L,
                    timelineStartNs = 20_000_000L,
                ),
            ),
        )
        TimelineWavReader(plan).use { reader ->
            assertEquals(2400L, reader.totalFrames)
            assertEquals(150L, reader.durationMs)

            val output = ShortArray(2400)
            val chunk = ShortArray(137)
            var written = 0
            while (true) {
                val read = reader.readFrames(chunk, 137)
                if (read == 0) break
                chunk.copyInto(output, destinationOffset = written, startIndex = 0, endIndex = read)
                written += read
            }
            assertEquals(2400, written)
            assertArrayEquals(ShortArray(320), output.copyOfRange(0, 320))
            assertArrayEquals(ShortArray(160) { 8192 }, output.copyOfRange(320, 480))
            assertArrayEquals(ShortArray(1120), output.copyOfRange(480, 1600))
            assertArrayEquals(ShortArray(160) { 16384 }, output.copyOfRange(1600, 1760))
            assertArrayEquals(ShortArray(640), output.copyOfRange(1760, 2400))

            reader.seekToMs(60L)
            assertEquals(960L, reader.positionFrame)
            val crossBoundary = ShortArray(700)
            assertEquals(700, reader.readFrames(crossBoundary, 700))
            assertArrayEquals(ShortArray(640), crossBoundary.copyOfRange(0, 640))
            assertArrayEquals(ShortArray(60) { 16384 }, crossBoundary.copyOfRange(640, 700))
        }
    }

    @Test
    fun segmentClippingSafelyBoundsSamplesExceedingWavDataLength() = withTempDir { dir ->
        val wavFile = File(dir, "clipped.wav")
        val samples = ShortArray(100) { 4096 }
        writeWav(file = wavFile, sampleRate = 16_000, channels = 1, samples = samples)

        val plan = PlaybackAssetSnapshot(
            audioPath = wavFile.absolutePath,
            sampleRate = 16_000,
            durationNs = 0L,
            segments = listOf(
                PlaybackSegmentSnapshot(
                    sourceStartSample = 80L,
                    sampleCount = 50L,
                    timelineStartNs = 0L,
                ),
                PlaybackSegmentSnapshot(
                    sourceStartSample = 200L,
                    sampleCount = 25L,
                    timelineStartNs = 10_000_000L,
                ),
            ),
        )
        TimelineWavReader(plan).use { reader ->
            assertEquals(20L, reader.totalFrames)
            val out = ShortArray(32)
            assertEquals(20, reader.readFrames(out, 32))
            assertArrayEquals(ShortArray(20) { 4096 }, out.copyOfRange(0, 20))
            assertEquals(0, reader.readFrames(out, 32))
        }
    }

    @Test
    fun rejectsMissingInvalidNonPcmAndTruncatedWavFiles() = withTempDir { dir ->
        val missing = File(dir, "does-not-exist.wav")
        assertThrows(IOException::class.java) {
            TimelineWavReader(PlaybackAssetSnapshot(audioPath = missing.absolutePath))
        }

        val badHeader = File(dir, "not-riff.wav")
        badHeader.writeBytes("OggS0123456789abcdef".toByteArray(StandardCharsets.US_ASCII))
        assertThrows(IllegalArgumentException::class.java) {
            TimelineWavReader(PlaybackAssetSnapshot(audioPath = badHeader.absolutePath))
        }

        val floatWav = File(dir, "float.wav")
        writeWav(
            file = floatWav,
            sampleRate = 16_000,
            channels = 1,
            samples = ShortArray(16),
            audioFormat = 3,
        )
        assertThrows(IllegalArgumentException::class.java) {
            TimelineWavReader(PlaybackAssetSnapshot(audioPath = floatWav.absolutePath))
        }

        val twentyFourBit = File(dir, "pcm24.wav")
        writeWav(
            file = twentyFourBit,
            sampleRate = 16_000,
            channels = 1,
            samples = ShortArray(16),
            bitsPerSample = 24,
        )
        assertThrows(IllegalArgumentException::class.java) {
            TimelineWavReader(PlaybackAssetSnapshot(audioPath = twentyFourBit.absolutePath))
        }

        val truncated = File(dir, "truncated.wav")
        writeWav(
            file = truncated,
            sampleRate = 16_000,
            channels = 1,
            samples = ShortArray(16),
            declaredDataSizeOverride = 4096,
        )
        assertThrows(IOException::class.java) {
            TimelineWavReader(PlaybackAssetSnapshot(audioPath = truncated.absolutePath))
        }

        val valid = File(dir, "valid.wav")
        writeWav(file = valid, sampleRate = 16_000, channels = 1, samples = ShortArray(16))
        assertThrows(IllegalArgumentException::class.java) {
            TimelineWavReader(
                PlaybackAssetSnapshot(
                    audioPath = valid.absolutePath,
                    sampleRate = 0,
                ),
            )
        }
    }
}
