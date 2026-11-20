package com.semanticcraft.koe.platform.capture

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

class MicrophoneMailboxTest {
    @Test
    fun stoppedProducerKeepsAcceptedTailUntilAcknowledged() {
        val mailbox = MicrophoneMailbox(nextSequence = 0L)
        mailbox.append(CapturedPcm(shortArrayOf(1, 2), capturedStartNs = 100L))
        mailbox.append(CapturedPcm(shortArrayOf(3, 4), capturedStartNs = 200L))
        mailbox.close()
        mailbox.append(CapturedPcm(shortArrayOf(9), capturedStartNs = 300L))

        assertEquals(2L, mailbox.finalSequence)
        assertNull(mailbox.error)
        assertEquals(0L, mailbox.peek()?.sequence)
        assertArrayEquals(shortArrayOf(1, 2), mailbox.peek()?.pcm?.samples)

        mailbox.acknowledge(0L)
        assertEquals(1L, mailbox.peek()?.sequence)
        assertArrayEquals(shortArrayOf(3, 4), mailbox.peek()?.pcm?.samples)

        mailbox.acknowledge(1L)
        assertNull(mailbox.peek())
    }

    @Test
    fun backpressurePreservesUnacknowledgedBlocksAndBoundsQueue() {
        val mailbox = MicrophoneMailbox(nextSequence = 0L, limit = 64)
        for (i in 0 until 65) {
            mailbox.append(CapturedPcm(shortArrayOf(i.toShort()), capturedStartNs = i.toLong()))
        }

        assertEquals(64L, mailbox.finalSequence)
        assertEquals("音频处理未能跟上采集，已停止并保留已接收的音频。", mailbox.error)

        mailbox.acknowledge(9L)
        assertEquals(0L, mailbox.peek()?.sequence)

        mailbox.close()
        for (sequence in 0L until 64L) {
            assertEquals(sequence, mailbox.peek()?.sequence)
            mailbox.acknowledge(sequence)
        }
        assertNull(mailbox.peek())
    }

    @Test
    fun emptyAndOversizedChunksFailAndCloseMailbox() {
        val emptyBox = MicrophoneMailbox(nextSequence = 0L)
        emptyBox.append(CapturedPcm(ShortArray(0), capturedStartNs = 0L))
        assertNotNull(emptyBox.error)
        assertNull(emptyBox.peek())
        assertEquals(0L, emptyBox.finalSequence)

        val oversizedBox = MicrophoneMailbox(nextSequence = 5L)
        oversizedBox.append(CapturedPcm(ShortArray(8192) { 1 }, capturedStartNs = 10L))
        assertNull(oversizedBox.error)
        assertEquals(6L, oversizedBox.finalSequence)

        oversizedBox.append(CapturedPcm(ShortArray(8193) { 2 }, capturedStartNs = 20L))
        assertNotNull(oversizedBox.error)
        assertEquals(6L, oversizedBox.finalSequence)
        assertEquals(5L, oversizedBox.peek()?.sequence)
    }

    @Test
    fun ringBufferWraparoundDiscardUnacceptedAndFirstErrorPreserved() {
        val mailbox = MicrophoneMailbox(nextSequence = 10L, limit = 4)
        for (index in 0 until 10) {
            val expectedSeq = 10L + index
            mailbox.append(CapturedPcm(shortArrayOf(index.toShort()), capturedStartNs = index * 100L))
            val head = mailbox.peek()
            assertEquals(expectedSeq, head?.sequence)
            assertArrayEquals(shortArrayOf(index.toShort()), head?.pcm?.samples)
            mailbox.acknowledge(expectedSeq)
            assertNull(mailbox.peek())
        }

        for (index in 10 until 14) {
            mailbox.append(CapturedPcm(shortArrayOf(index.toShort()), capturedStartNs = 0L))
        }
        assertNull(mailbox.error)
        assertEquals(24L, mailbox.finalSequence)

        mailbox.acknowledge(20L)
        mailbox.acknowledge(21L)
        mailbox.append(CapturedPcm(shortArrayOf(99), capturedStartNs = 0L))
        assertNull(mailbox.error)
        assertEquals(22L, mailbox.peek()?.sequence)

        mailbox.fail("first error")
        mailbox.fail("second error")
        assertEquals("first error", mailbox.error)

        mailbox.discardUnaccepted(nextSequence = 22L)
        assertNull(mailbox.peek())
        assertEquals(22L, mailbox.finalSequence)
    }
}
