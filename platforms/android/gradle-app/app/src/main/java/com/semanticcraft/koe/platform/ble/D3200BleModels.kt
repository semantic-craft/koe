package com.semanticcraft.koe.platform.ble

import java.util.Locale

const val D3200_SERVICE_UUID = "020cf5da-0000-1000-8000-00805f9b34fb"
const val D3200_WRITE_UUID = "00007777-0000-1000-8000-00805f9b34fb"
const val D3200_NOTIFY_UUID = "00008888-0000-1000-8000-00805f9b34fb"
const val CCCD_UUID = "00002902-0000-1000-8000-00805f9b34fb"
const val REQUESTED_MTU = 247
const val DEFAULT_PAYLOAD_MTU = 20

fun isPrimaryD3200Service(uuid: String): Boolean {
    val normalized = uuid.lowercase(Locale.ROOT)
    return normalized == D3200_SERVICE_UUID || normalized.contains("020cf5da") || normalized == "f5da"
}

fun isWriteCharacteristic(uuid: String): Boolean = uuid.lowercase(Locale.ROOT).contains("7777")

fun isNotifyCharacteristic(uuid: String): Boolean = uuid.lowercase(Locale.ROOT).contains("8888")

fun isD3200WriteCharacteristic(uuid: String, serviceUuid: String?): Boolean =
    serviceUuid != null && isPrimaryD3200Service(serviceUuid) && isWriteCharacteristic(uuid)

fun isD3200NotifyCharacteristic(uuid: String, serviceUuid: String?): Boolean =
    serviceUuid != null && isPrimaryD3200Service(serviceUuid) && isNotifyCharacteristic(uuid)

fun shouldPreferWriteCharacteristic(existingServiceUuid: String?, candidateServiceUuid: String): Boolean {
    if (existingServiceUuid == null) return true
    return if (isPrimaryD3200Service(existingServiceUuid)) {
        isPrimaryD3200Service(candidateServiceUuid)
    } else {
        true
    }
}

data class BleAdvertisementCandidate(
    val displayName: String,
    val macAddress: String,
    val matchedByServiceUuid: Boolean,
    val matchedByManufacturerData: Boolean,
    val matchedByName: Boolean,
) {
    companion object {
        fun match(
            deviceName: String?,
            localName: String?,
            serviceUuids: List<String>,
            manufacturerData: List<ByteArray>,
        ): BleAdvertisementCandidate? {
            val matchedByService = serviceUuids.any { raw ->
                val lower = raw.lowercase(Locale.ROOT)
                lower.contains("020cf5da") || lower.contains("daf50c02") || lower.contains("f5da")
            }

            val trimmedDevice = deviceName?.trim().orEmpty()
            val trimmedLocal = localName?.trim().orEmpty()
            val rawName = if (trimmedDevice.isNotEmpty()) trimmedDevice else trimmedLocal
            val lowerName = rawName.lowercase(Locale.ROOT)
            val matchedByName = lowerName.contains("soundcore") || lowerName.contains("d3200")

            var matchedByMfg = false
            var macAddress = ""
            for (bytes in manufacturerData) {
                var entryMatched = false
                var macBase = 0
                if (bytes.size >= 16) {
                    val mark = bytes.copyOfRange(10, 16).decodeToString().lowercase(Locale.ROOT)
                    if (mark.contains("sound") || mark.contains("scor")) {
                        entryMatched = true
                        macBase = 2
                    }
                }
                if (!entryMatched && bytes.size >= 14) {
                    val mark = bytes.copyOfRange(8, 14).decodeToString().lowercase(Locale.ROOT)
                    if (mark.contains("sound") || mark.contains("scor")) {
                        entryMatched = true
                        macBase = 0
                    }
                }
                if (!entryMatched && bytes.size >= 7) {
                    for (index in 0 until bytes.size - 1) {
                        val b0 = bytes[index].toInt() and 0xFF
                        val b1 = bytes[index + 1].toInt() and 0xFF
                        if ((b0 == 0xF5 && b1 == 0xDA) || (b0 == 0xDA && b1 == 0xF5)) {
                            entryMatched = true
                            break
                        }
                    }
                }
                if (entryMatched) {
                    matchedByMfg = true
                }
                if (macAddress.isEmpty() &&
                    bytes.size >= macBase + 6 &&
                    (entryMatched || matchedByService || matchedByName)
                ) {
                    macAddress = formatMac(bytes, macBase)
                }
            }

            if (!matchedByService && !matchedByMfg && !matchedByName) return null

            val displayName = when {
                rawName.isNotEmpty() -> rawName
                macAddress.length >= 5 -> "soundcore Work (${macAddress.takeLast(5)})"
                else -> "soundcore Work"
            }
            return BleAdvertisementCandidate(
                displayName = displayName,
                macAddress = macAddress,
                matchedByServiceUuid = matchedByService,
                matchedByManufacturerData = matchedByMfg,
                matchedByName = matchedByName,
            )
        }

        private fun formatMac(bytes: ByteArray, offset: Int): String {
            if (bytes.size < offset + 6) return ""
            val slice = IntArray(6) { bytes[offset + it].toInt() and 0xFF }
            val first = slice[0]
            if (slice.all { it == first } || slice.all { it == 0 }) return ""
            return slice.joinToString(":") { "%02X".format(Locale.ROOT, it) }
        }
    }
}

object BleHex {
    fun decode(hex: String): ByteArray? {
        if (hex.length % 2 != 0) return null
        val out = ByteArray(hex.length / 2)
        var index = 0
        while (index < hex.length) {
            val hi = Character.digit(hex[index], 16)
            val lo = Character.digit(hex[index + 1], 16)
            if (hi < 0 || lo < 0) return null
            out[index / 2] = ((hi shl 4) or lo).toByte()
            index += 2
        }
        return out
    }
}

class BleOutboundQueue(
    val spacingMs: Long = 300L,
    val inFlightTimeoutMs: Long = 5_000L,
) {
    private val pendingFrames = ArrayDeque<ByteArray>()

    var lastWriteMs: Long? = null
        private set

    var inFlightSinceMs: Long? = null
        private set

    val isEmpty: Boolean
        get() = pendingFrames.isEmpty()

    fun enqueueFragmented(frames: List<ByteArray>, maxChunkBytes: Int) {
        val limit = maxChunkBytes.coerceAtLeast(1)
        for (frame in frames) {
            if (frame.isEmpty()) continue
            var offset = 0
            while (offset < frame.size) {
                val end = minOf(offset + limit, frame.size)
                pendingFrames.addLast(frame.copyOfRange(offset, end))
                offset = end
            }
        }
    }

    fun popReady(nowMs: Long): ByteArray? {
        if (pendingFrames.isEmpty()) return null
        val inFlight = inFlightSinceMs
        if (inFlight != null && nowMs - inFlight < inFlightTimeoutMs) return null
        val last = lastWriteMs
        if (last != null && nowMs - last < spacingMs) return null
        val next = pendingFrames.removeFirst()
        lastWriteMs = nowMs
        inFlightSinceMs = nowMs
        return next
    }

    fun requeueFront(frame: ByteArray) {
        pendingFrames.addFirst(frame)
        inFlightSinceMs = null
    }

    fun markWriteCompleted() {
        inFlightSinceMs = null
    }

    fun delayUntilNextReadyMs(nowMs: Long): Long? {
        if (pendingFrames.isEmpty()) return null
        val inFlightWait = inFlightSinceMs?.let { (inFlightTimeoutMs - (nowMs - it)).coerceAtLeast(0L) } ?: 0L
        val spacingWait = lastWriteMs?.let { (spacingMs - (nowMs - it)).coerceAtLeast(0L) } ?: 0L
        return maxOf(inFlightWait, spacingWait)
    }

    fun reset() {
        pendingFrames.clear()
        lastWriteMs = null
        inFlightSinceMs = null
    }
}
