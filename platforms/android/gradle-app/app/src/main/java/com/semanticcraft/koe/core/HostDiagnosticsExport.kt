package com.semanticcraft.koe.core

import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject

private val prettyDiagnosticsJson = Json {
    prettyPrint = true
    encodeDefaults = true
}

fun diagnosticsBundleFilename(nowEpochSec: Long = 0L): String {
    val effectiveNow = if (nowEpochSec > 0L) nowEpochSec else (System.currentTimeMillis() / 1_000L).coerceAtLeast(0L)
    return "koe-diagnostics-$effectiveNow.json"
}

fun HostSessionStore.exportDiagnosticsBundleJson(nowEpochSec: Long = 0L): String {
    val rawRust = exportRustDiagnosticsJson(nowEpochSec)
    val rustElement = if (rawRust == null) {
        if (handle != 0L) {
            KoeLogger.e(
                tag = "KoeDiagnostics",
                operation = "export_rust_null_response",
                message = "bridge returned null diagnostics bundle",
                errorCode = "ffi_diagnostics_null",
            )
        }
        JsonNull
    } else {
        try {
            HostJson.json.parseToJsonElement(rawRust)
        } catch (error: Exception) {
            KoeLogger.e(
                tag = "KoeDiagnostics",
                operation = "parse_rust_bundle_failed",
                message = "failed to parse rust diagnostics bundle",
                errorCode = error.javaClass.simpleName,
                error = error,
            )
            JsonNull
        }
    }

    val hostDiagnosticsElement = HostJson.json.encodeToJsonElement(
        ListSerializer(DiagnosticLogEntry.serializer()),
        KoeLogger.recentEntries(),
    )
    val hostTraceElement = HostJson.json.encodeToJsonElement(
        ListSerializer(HostTraceEntry.serializer()),
        recentTraceEntries(),
    )

    val merged = buildJsonObject {
        put("rust", rustElement)
        put("hostDiagnostics", hostDiagnosticsElement)
        put("hostTrace", hostTraceElement)
    }
    return prettyDiagnosticsJson.encodeToString(JsonObject.serializer(), merged)
}
