package com.semanticcraft.koe.core

import java.io.File
import java.io.FileOutputStream
import java.nio.charset.StandardCharsets
import java.nio.file.AtomicMoveNotSupportedException
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.util.UUID
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer

@Serializable
data class HostTraceEntry(
    val kind: String,
    val name: String,
    val generation: Long,
    val section: String,
    val hasError: Boolean,
    val timestampEpochMs: Long,
)

class HostTraceRingBuffer(capacity: Int = DEFAULT_CAPACITY) {
    private val maxCapacity: Int = capacity.coerceAtLeast(1)
    private val lock = Any()
    private val entries = ArrayDeque<HostTraceEntry>(maxCapacity)

    fun append(entry: HostTraceEntry) {
        synchronized(lock) {
            if (entries.size >= maxCapacity) {
                entries.removeFirst()
            }
            entries.addLast(entry)
        }
    }

    fun snapshot(): List<HostTraceEntry> = synchronized(lock) { entries.toList() }

    fun exportJson(): String {
        val current = snapshot()
        return HostJson.json.encodeToString(ListSerializer(HostTraceEntry.serializer()), current)
    }

    fun writeAtomically(targetFile: File): Boolean {
        val payload = exportJson().toByteArray(StandardCharsets.UTF_8)
        val parent = targetFile.parentFile ?: File(".")
        if (!parent.exists() && !parent.mkdirs()) {
            return false
        }
        val tempFile = File(parent, ".${targetFile.name}.${UUID.randomUUID()}.tmp")
        return try {
            FileOutputStream(tempFile).use { stream ->
                stream.write(payload)
                stream.flush()
                stream.fd.sync()
            }
            try {
                Files.move(
                    tempFile.toPath(),
                    targetFile.toPath(),
                    StandardCopyOption.REPLACE_EXISTING,
                    StandardCopyOption.ATOMIC_MOVE,
                )
            } catch (_: AtomicMoveNotSupportedException) {
                Files.move(
                    tempFile.toPath(),
                    targetFile.toPath(),
                    StandardCopyOption.REPLACE_EXISTING,
                )
            }
            true
        } catch (_: Exception) {
            tempFile.delete()
            false
        }
    }

    companion object {
        const val DEFAULT_CAPACITY = 20
    }
}
