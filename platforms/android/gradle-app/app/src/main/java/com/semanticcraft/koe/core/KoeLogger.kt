package com.semanticcraft.koe.core

import android.util.Log
import kotlinx.serialization.ExperimentalSerializationApi
import kotlinx.serialization.MissingFieldException
import kotlinx.serialization.Serializable

enum class DiagnosticLogLevel(val label: String) {
    INFO("info"),
    WARN("warning"),
    ERROR("error"),
}

@Serializable
data class DiagnosticLogEntry(
    val timestampEpochMs: Long,
    val level: String,
    val tag: String,
    val operation: String,
    val message: String,
    val errorCode: String? = null,
)

fun interface LogSink {
    fun emit(level: DiagnosticLogLevel, tag: String, message: String)
}

object KoeLogger {
    const val MAX_CAPACITY = 200
    const val MAX_MESSAGE_CHARS = 300

    private val jsonInputSnippetRegex = Regex("\\r?\\n\\s*JSON input:[\\s\\S]*$")
    private val jsonAuthorizationRegex = Regex("(?i)\"authorization\"\\s*:\\s*\"[^\"]*(?:\"|$)")
    private val kvAuthorizationRegex = Regex(
        "(?i)\\bauthorization\\s*([:=])\\s*(?:\"[^\"]*(?:\"|$)|'[^']*(?:'|$)|(?:[A-Za-z][A-Za-z0-9_-]*[ \\t]+)?[^\\s,;&}\"'\\]]+)",
    )
    private val bearerRegex = Regex("(?i)\\bBearer\\s+[A-Za-z0-9._~+/=-]+")
    private val apiKeyTokenRegex = Regex("(?<![A-Za-z0-9])sk-[A-Za-z0-9_.-]+")
    private val jsonSecretRegex = Regex(
        "(?i)\"([A-Za-z0-9_.-]*(?:api[_-]?key|token|secret|password|private[_-]?key))\"\\s*:\\s*\"[^\"]*(?:\"|$)",
    )
    private val kvSecretRegex = Regex(
        "(?i)(?<![A-Za-z0-9_.-])([\"']?)([A-Za-z0-9_.-]*(?:api[_-]?key|token|secret|password|private[_-]?key))\\1\\s*([:=])\\s*(?:\"(?!\\[REDACTED]\")[^\"]*(?:\"|$)|'[^']*(?:'|$)|[^\\s,;&}\\]]+)",
    )

    private val defaultSink = LogSink { level, tag, message ->
        try {
            when (level) {
                DiagnosticLogLevel.INFO -> Log.i(tag, message)
                DiagnosticLogLevel.WARN -> Log.w(tag, message)
                DiagnosticLogLevel.ERROR -> Log.e(tag, message)
            }
        } catch (_: RuntimeException) {
        } catch (_: LinkageError) {
        }
    }

    private val lock = Any()
    private val buffer = ArrayDeque<DiagnosticLogEntry>(MAX_CAPACITY)

    @Volatile
    private var sink: LogSink = defaultSink

    fun setSinkForTests(customSink: LogSink?) {
        sink = customSink ?: defaultSink
    }

    fun clearForTests() {
        synchronized(lock) {
            buffer.clear()
        }
    }

    fun recentEntries(): List<DiagnosticLogEntry> = synchronized(lock) {
        buffer.toList()
    }

    fun i(
        tag: String,
        operation: String,
        message: String = "",
        errorCode: String? = null,
    ): String = record(DiagnosticLogLevel.INFO, tag, operation, message, errorCode, null)

    fun w(
        tag: String,
        operation: String,
        message: String,
        errorCode: String? = null,
        error: Throwable? = null,
    ): String = record(DiagnosticLogLevel.WARN, tag, operation, message, errorCode, error)

    fun e(
        tag: String,
        operation: String,
        message: String,
        errorCode: String? = null,
        error: Throwable? = null,
    ): String = record(DiagnosticLogLevel.ERROR, tag, operation, message, errorCode, error)

    fun redact(message: String): String {
        val singleLine = message
            .replace("\r\n", " ")
            .replace('\n', ' ')
            .replace('\r', ' ')
            .replace('\t', ' ')
        val noJsonAuth = jsonAuthorizationRegex.replace(singleLine, "\"authorization\":\"[REDACTED]\"")
        val noKvAuth = kvAuthorizationRegex.replace(noJsonAuth, "Authorization$1 [REDACTED]")
        val noBearer = bearerRegex.replace(noKvAuth, "Bearer [REDACTED]")
        val noApiKey = apiKeyTokenRegex.replace(noBearer, "[REDACTED]")
        val noJsonSecret = jsonSecretRegex.replace(noApiKey, "\"$1\":\"[REDACTED]\"")
        val noKvSecret = kvSecretRegex.replace(noJsonSecret, "$1$2$1$3[REDACTED]")
        return truncateChars(noKvSecret, MAX_MESSAGE_CHARS)
    }

    fun formatDetail(message: String, error: Throwable? = null): String {
        val combined = when {
            error != null && message.isNotBlank() -> "$message (${describeException(error)})"
            error != null -> describeException(error)
            else -> message
        }
        return redact(combined)
    }

    internal class PendingError(
        private val tag: String,
        private val operation: String,
        private val message: String,
        private val errorCode: String?,
        private val error: Throwable? = null,
    ) {
        val detail: String = formatDetail(message, error)
        fun emit() { e(tag, operation, message, errorCode, error) }
    }

    @OptIn(ExperimentalSerializationApi::class)
    fun describeException(error: Throwable): String {
        val name = error.javaClass.simpleName.ifBlank { error.javaClass.name }
        val rawMessage = error.message
            ?.let { jsonInputSnippetRegex.replace(it, "") }
            ?.trim()
            ?.takeIf { it.isNotBlank() }
        val detail = when (error) {
            is MissingFieldException -> {
                val fields = error.missingFields.joinToString(",")
                if (rawMessage != null) "$name missingFields=[$fields] $rawMessage" else "$name missingFields=[$fields]"
            }
            else -> if (rawMessage != null) "$name: $rawMessage" else name
        }
        return redact(detail)
    }

    private fun record(
        level: DiagnosticLogLevel,
        tag: String,
        operation: String,
        message: String,
        errorCode: String?,
        error: Throwable?,
    ): String {
        val redactedMessage = formatDetail(message, error)
        val redactedCode = errorCode?.let(::redact)
        val entry = DiagnosticLogEntry(
            timestampEpochMs = System.currentTimeMillis().coerceAtLeast(0L),
            level = level.label,
            tag = tag,
            operation = operation,
            message = redactedMessage,
            errorCode = redactedCode,
        )
        synchronized(lock) {
            if (buffer.size >= MAX_CAPACITY) {
                buffer.removeFirst()
            }
            buffer.addLast(entry)
        }
        val codeSuffix = redactedCode?.let { " code=$it" }.orEmpty()
        val formatted = if (redactedMessage.isEmpty()) {
            "$operation$codeSuffix"
        } else {
            "$operation$codeSuffix $redactedMessage"
        }
        sink.emit(level, tag, formatted)
        return redactedMessage
    }

    private fun truncateChars(text: String, maxChars: Int): String {
        if (text.length <= maxChars) return text
        val ellipsis = "..."
        var end = (maxChars - ellipsis.length).coerceAtLeast(0)
        if (end > 0 && Character.isHighSurrogate(text[end - 1])) {
            end -= 1
        }
        return text.substring(0, end) + ellipsis
    }
}
