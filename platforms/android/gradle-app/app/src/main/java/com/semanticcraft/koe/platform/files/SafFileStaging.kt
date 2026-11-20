package com.semanticcraft.koe.platform.files

import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.io.InputStream
import java.util.Locale
import java.util.UUID

const val MAX_IMPORT_BYTES: Long = 256L * 1024L * 1024L

val ALLOWED_IMPORT_EXTENSIONS: Set<String> = setOf("wav", "txt", "md", "koepack")

private const val STAGE_BUFFER_BYTES: Int = 64 * 1024

private val INVALID_EXPORT_CHARS: Set<Char> = setOf('/', '\\', ':', '*', '?', '"', '<', '>', '|')

sealed interface ImportFileNameResult {
    data class Valid(val fileName: String) : ImportFileNameResult
    data object InvalidPath : ImportFileNameResult
    data object UnsupportedExtension : ImportFileNameResult
}

sealed interface StageImportResult {
    data class Success(val runDir: File, val file: File) : StageImportResult
    data object TooLarge : StageImportResult
    data class IoError(val message: String) : StageImportResult
}

fun resolveImportFileName(displayName: String?, mimeType: String?): ImportFileNameResult {
    if (displayName != null && displayName.any { it.code < 0x20 || it.code == 0x7F || it == '/' || it == '\\' }) {
        return ImportFileNameResult.InvalidPath
    }
    val trimmed = displayName?.trim().orEmpty()
    if (trimmed.isEmpty()) {
        return when (inferExtensionFromMime(mimeType)) {
            "wav" -> ImportFileNameResult.Valid("导入音频.wav")
            "md" -> ImportFileNameResult.Valid("导入文稿.md")
            "txt" -> ImportFileNameResult.Valid("导入文本.txt")
            else -> ImportFileNameResult.UnsupportedExtension
        }
    }
    if (trimmed == "." || trimmed == ".." || trimmed.contains("..") || trimmed.startsWith('.')) {
        return ImportFileNameResult.InvalidPath
    }
    val lastDot = trimmed.lastIndexOf('.')
    if (lastDot < 0) {
        val inferred = inferExtensionFromMime(mimeType) ?: return ImportFileNameResult.UnsupportedExtension
        return ImportFileNameResult.Valid("$trimmed.$inferred")
    }
    val ext = trimmed.substring(lastDot + 1).lowercase(Locale.ROOT)
    return if (ext in ALLOWED_IMPORT_EXTENSIONS) {
        ImportFileNameResult.Valid(trimmed)
    } else {
        ImportFileNameResult.UnsupportedExtension
    }
}

fun sanitizeExportFileName(
    rawName: String?,
    defaultBase: String = "Koe 记录",
    extension: String = "md",
): String {
    val cleanExt = extension.trim().trimStart('.').ifEmpty { "md" }
    val suffix = ".$cleanExt"
    val trimmed = rawName.orEmpty().trim()
    val withoutExt = if (trimmed.endsWith(suffix, ignoreCase = true)) {
        trimmed.dropLast(suffix.length)
    } else {
        trimmed
    }
    val replaced = buildString(withoutExt.length) {
        for (ch in withoutExt) {
            if (ch.code < 0x20 || ch.code == 0x7F || ch in INVALID_EXPORT_CHARS) {
                append('-')
            } else {
                append(ch)
            }
        }
    }
    val base = replaced
        .trimStart { it == '.' || it.isWhitespace() }
        .trimEnd()
        .ifEmpty { defaultBase }
    return "$base.$cleanExt"
}

fun createTempStagingDir(stagingRoot: File): File {
    val runDir = File(stagingRoot, UUID.randomUUID().toString())
    if (!runDir.mkdirs() && !runDir.isDirectory) {
        throw IOException("Failed to create staging directory: ${runDir.absolutePath}")
    }
    return runDir
}

fun stageInputStreamToFile(
    input: InputStream,
    stagingRoot: File,
    fileName: String,
    maxBytes: Long = MAX_IMPORT_BYTES,
): StageImportResult {
    if (maxBytes < 0L) {
        return StageImportResult.TooLarge
    }
    if (fileName.isBlank() || fileName.any { it.code < 0x20 || it.code == 0x7F || it == '/' || it == '\\' }) {
        return StageImportResult.IoError("目标文件名无效")
    }
    val runDir = try {
        createTempStagingDir(stagingRoot)
    } catch (e: IOException) {
        return StageImportResult.IoError(e.message ?: "无法创建临时目录")
    }

    var overflow = false
    try {
        val canonicalRunDir = runDir.canonicalFile
        val canonicalTarget = File(canonicalRunDir, fileName).canonicalFile
        val expectedPrefix = canonicalRunDir.path.trimEnd(File.separatorChar) + File.separatorChar
        if (!canonicalTarget.path.startsWith(expectedPrefix) || canonicalTarget.parentFile != canonicalRunDir) {
            runDir.deleteRecursively()
            return StageImportResult.IoError("目标路径越界")
        }

        val buffer = ByteArray(STAGE_BUFFER_BYTES)
        var total = 0L
        FileOutputStream(canonicalTarget).use { output ->
            while (true) {
                val read = input.read(buffer)
                if (read < 0) break
                if (read == 0) continue
                total += read.toLong()
                if (total > maxBytes) {
                    overflow = true
                    break
                }
                output.write(buffer, 0, read)
            }
            if (!overflow) {
                output.flush()
            }
        }
        if (overflow) {
            runDir.deleteRecursively()
            return StageImportResult.TooLarge
        }
        return StageImportResult.Success(runDir = runDir, file = canonicalTarget)
    } catch (e: IOException) {
        runDir.deleteRecursively()
        return StageImportResult.IoError(e.message ?: "无法读取所选文件")
    } catch (e: SecurityException) {
        runDir.deleteRecursively()
        return StageImportResult.IoError(e.message ?: "无法读取所选文件")
    } catch (t: Throwable) {
        runDir.deleteRecursively()
        throw t
    }
}

private fun inferExtensionFromMime(mimeType: String?): String? {
    val normalized = mimeType
        ?.substringBefore(';')
        ?.trim()
        ?.lowercase(Locale.ROOT)
        ?: return null
    return when (normalized) {
        "audio/wav", "audio/x-wav", "audio/wave", "audio/vnd.wave" -> "wav"
        "text/markdown", "text/x-markdown" -> "md"
        "text/plain" -> "txt"
        else -> null
    }
}
