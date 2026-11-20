package com.semanticcraft.koe.platform.ble

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class D3200BleModelsTest {
    @Test
    fun advertisementMatchRecognizesServiceUuidNameAndManufacturerDataAndRejectsUnrelated() {
        val serviceMatch = BleAdvertisementCandidate.match(
            deviceName = null,
            localName = null,
            serviceUuids = listOf(D3200_SERVICE_UUID),
            manufacturerData = emptyList(),
        )
        assertNotNull(serviceMatch)
        assertTrue(serviceMatch!!.matchedByServiceUuid)
        assertEquals("soundcore Work", serviceMatch.displayName)

        val shortServiceMatch = BleAdvertisementCandidate.match(
            deviceName = null,
            localName = null,
            serviceUuids = listOf("f5da"),
            manufacturerData = emptyList(),
        )
        assertNotNull(shortServiceMatch)
        assertTrue(shortServiceMatch!!.matchedByServiceUuid)

        val rawMfg = byteArrayOf(
            0x00, 0x7F, 0x1D, 0x04, 0xCC.toByte(), 0xA3.toByte(),
            0x90.toByte(), 0x00, 0x73, 0x6F, 0x75, 0x6E, 0x64, 0x63,
        )
        val rawMfgMatch = BleAdvertisementCandidate.match(
            deviceName = null,
            localName = null,
            serviceUuids = emptyList(),
            manufacturerData = listOf(rawMfg),
        )
        assertNotNull(rawMfgMatch)
        assertTrue(rawMfgMatch!!.matchedByManufacturerData)
        assertEquals("00:7F:1D:04:CC:A3", rawMfgMatch.macAddress)
        assertEquals("soundcore Work (CC:A3)", rawMfgMatch.displayName)

        val prefixedMfg = byteArrayOf(
            0xFF.toByte(), 0xFF.toByte(),
            0x00, 0x7F, 0x1D, 0x04, 0xCC.toByte(), 0xA3.toByte(),
            0x90.toByte(), 0x00, 0x73, 0x6F, 0x75, 0x6E, 0x64, 0x63,
        )
        val prefixedMatch = BleAdvertisementCandidate.match(
            deviceName = null,
            localName = null,
            serviceUuids = emptyList(),
            manufacturerData = listOf(prefixedMfg),
        )
        assertNotNull(prefixedMatch)
        assertEquals("00:7F:1D:04:CC:A3", prefixedMatch!!.macAddress)
        assertEquals("soundcore Work (CC:A3)", prefixedMatch.displayName)

        val scorMfg = byteArrayOf(
            0x01, 0x02, 0x03, 0x04, 0x05, 0x06,
            0x00, 0x00, 0x73, 0x63, 0x6F, 0x72, 0x30, 0x31,
        )
        val scorMatch = BleAdvertisementCandidate.match(
            deviceName = null,
            localName = null,
            serviceUuids = emptyList(),
            manufacturerData = listOf(scorMfg),
        )
        assertNotNull(scorMatch)
        assertTrue(scorMatch!!.matchedByManufacturerData)
        assertEquals("01:02:03:04:05:06", scorMatch.macAddress)

        val magicBytesMfg = byteArrayOf(0x01, 0x02, 0xF5.toByte(), 0xDA.toByte(), 0x05, 0x06, 0x07)
        val magicMatch = BleAdvertisementCandidate.match(
            deviceName = null,
            localName = null,
            serviceUuids = emptyList(),
            manufacturerData = listOf(magicBytesMfg),
        )
        assertNotNull(magicMatch)
        assertTrue(magicMatch!!.matchedByManufacturerData)

        val nameMatch = BleAdvertisementCandidate.match(
            deviceName = "soundcore Work",
            localName = null,
            serviceUuids = emptyList(),
            manufacturerData = emptyList(),
        )
        assertTrue(nameMatch?.matchedByName == true)

        val localNameMatch = BleAdvertisementCandidate.match(
            deviceName = null,
            localName = "D3200",
            serviceUuids = emptyList(),
            manufacturerData = emptyList(),
        )
        assertTrue(localNameMatch?.matchedByName == true)

        assertNull(
            BleAdvertisementCandidate.match(
                deviceName = "My Work Laptop",
                localName = null,
                serviceUuids = emptyList(),
                manufacturerData = emptyList(),
            ),
        )
        assertNull(
            BleAdvertisementCandidate.match(
                deviceName = null,
                localName = "Workshop Speaker",
                serviceUuids = listOf("0000180f-0000-1000-8000-00805f9b34fb"),
                manufacturerData = listOf(byteArrayOf(0x01, 0x02, 0x03)),
            ),
        )
    }

    @Test
    fun characteristicMatchingAndPrimaryServicePreference() {
        val secondaryService = "00007000-0000-1000-8000-00805f9b34fb"

        assertTrue(isPrimaryD3200Service(D3200_SERVICE_UUID))
        assertTrue(isPrimaryD3200Service("020CF5DA-0000-1000-8000-00805F9B34FB"))
        assertTrue(isPrimaryD3200Service("f5da"))
        assertFalse(isPrimaryD3200Service(secondaryService))

        assertTrue(isD3200WriteCharacteristic(D3200_WRITE_UUID, D3200_SERVICE_UUID))
        assertFalse(isD3200WriteCharacteristic(D3200_WRITE_UUID, secondaryService))
        assertFalse(isD3200WriteCharacteristic(D3200_WRITE_UUID, null))

        assertTrue(isD3200NotifyCharacteristic(D3200_NOTIFY_UUID, D3200_SERVICE_UUID))
        assertFalse(isD3200NotifyCharacteristic(D3200_NOTIFY_UUID, secondaryService))
        assertFalse(isD3200NotifyCharacteristic(D3200_NOTIFY_UUID, null))

        assertTrue(shouldPreferWriteCharacteristic(null, secondaryService))
        assertTrue(shouldPreferWriteCharacteristic(secondaryService, D3200_SERVICE_UUID))
        assertFalse(shouldPreferWriteCharacteristic(D3200_SERVICE_UUID, secondaryService))
        assertTrue(shouldPreferWriteCharacteristic(D3200_SERVICE_UUID, D3200_SERVICE_UUID))
    }

    @Test
    fun hexDecodeHandlesValidAndRejectsMalformedInput() {
        assertArrayEquals(
            byteArrayOf(0x09, 0xFF.toByte(), 0x00, 0x01),
            BleHex.decode("09ff0001"),
        )
        assertArrayEquals(
            byteArrayOf(0x08, 0xEE.toByte(), 0x00, 0x00, 0x00, 0x18, 0x82.toByte(), 0x0B, 0x00, 0x02, 0x9D.toByte()),
            BleHex.decode("08EE00000018820B00029D"),
        )
        assertNull(BleHex.decode("0"))
        assertNull(BleHex.decode("gg"))
        assertNull(BleHex.decode("0x12"))
    }

    @Test
    fun outboundQueueFragmentsGatesSingleInFlightEnforcesSpacingAndRecoversAfterTimeout() {
        val queue = BleOutboundQueue(spacingMs = 300L, inFlightTimeoutMs = 5_000L)
        val firstFrame = ByteArray(45) { it.toByte() }
        val secondFrame = byteArrayOf(0x01, 0x02, 0x03)
        queue.enqueueFragmented(listOf(firstFrame, secondFrame), maxChunkBytes = 20)

        assertEquals(0L, queue.delayUntilNextReadyMs(1_000L))
        val chunk1 = queue.popReady(1_000L)
        assertNotNull(chunk1)
        assertEquals(20, chunk1!!.size)
        assertEquals(1_000L, queue.lastWriteMs)
        assertEquals(1_000L, queue.inFlightSinceMs)

        assertNull(queue.popReady(1_400L))
        assertEquals(4_600L, queue.delayUntilNextReadyMs(1_400L))

        queue.markWriteCompleted()
        assertNull(queue.inFlightSinceMs)
        assertNull(queue.popReady(1_150L))
        assertEquals(150L, queue.delayUntilNextReadyMs(1_150L))

        val chunk2 = queue.popReady(1_300L)
        assertNotNull(chunk2)
        assertEquals(20, chunk2!!.size)
        assertNull(queue.popReady(6_299L))
        assertEquals(1L, queue.delayUntilNextReadyMs(6_299L))

        val chunk3 = queue.popReady(6_300L)
        assertNotNull(chunk3)
        assertEquals(5, chunk3!!.size)

        queue.reset()
        assertNull(queue.delayUntilNextReadyMs(7_000L))
        assertNull(queue.popReady(7_000L))
        assertNull(queue.lastWriteMs)
        assertNull(queue.inFlightSinceMs)
        assertFalse(queue.hasInFlight)
    }

    @Test
    fun replacePendingWithFragmentedDropsQueuedNormalFramesWhilePreservingInFlightAndSpacing() {
        val queue = BleOutboundQueue(spacingMs = 300L, inFlightTimeoutMs = 5_000L)
        queue.enqueueFragmented(listOf(byteArrayOf(1, 2), byteArrayOf(3, 4)), maxChunkBytes = 20)
        assertFalse(queue.hasInFlight)

        val first = queue.popReady(1_000L)
        assertArrayEquals(byteArrayOf(1, 2), first)
        assertTrue(queue.hasInFlight)

        val stopFrame = byteArrayOf(10, 11, 12, 13, 14)
        queue.replacePendingWithFragmented(listOf(stopFrame), maxChunkBytes = 3)
        assertTrue(queue.hasInFlight)
        assertEquals(1_000L, queue.inFlightSinceMs)
        assertEquals(1_000L, queue.lastWriteMs)
        assertNull(queue.popReady(1_100L))

        queue.markWriteCompleted()
        assertFalse(queue.hasInFlight)
        assertNull(queue.popReady(1_299L))

        assertArrayEquals(byteArrayOf(10, 11, 12), queue.popReady(1_300L))
        queue.markWriteCompleted()
        assertArrayEquals(byteArrayOf(13, 14), queue.popReady(1_600L))
        assertTrue(queue.isEmpty)
    }
}
