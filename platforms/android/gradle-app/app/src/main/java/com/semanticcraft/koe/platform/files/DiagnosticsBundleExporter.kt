package com.semanticcraft.koe.platform.files

import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.Context
import android.content.Intent
import androidx.core.content.FileProvider
import com.semanticcraft.koe.core.HostSessionStore
import com.semanticcraft.koe.core.KoeLogger
import com.semanticcraft.koe.core.diagnosticsBundleFilename
import com.semanticcraft.koe.core.exportDiagnosticsBundleJson
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.nio.charset.StandardCharsets
import java.nio.file.AtomicMoveNotSupportedException
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.util.UUID

fun interface DiagnosticsShareLauncher {
    fun shareDiagnosticsFile(file: File)
}

class AndroidDiagnosticsShareLauncher(
    private val context: Context,
    private val startChooser: (Intent) -> Unit = { intent -> context.startActivity(intent) },
) : DiagnosticsShareLauncher {
    override fun shareDiagnosticsFile(file: File) {
        val contentUri = FileProvider.getUriForFile(
            context,
            "${context.packageName}.fileprovider",
            file,
        )
        val sendIntent = Intent(Intent.ACTION_SEND).apply {
            type = JSON_MIME_TYPE
            putExtra(Intent.EXTRA_STREAM, contentUri)
            putExtra(Intent.EXTRA_SUBJECT, file.name)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            clipData = ClipData.newUri(context.contentResolver, file.name, contentUri)
        }
        val chooser = Intent.createChooser(sendIntent, "导出诊断包").apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        startChooser(chooser)
    }

    companion object {
        private const val JSON_MIME_TYPE = "application/json"
    }
}

internal object DiagnosticsBundleExporter {
    const val DIAGNOSTICS_EXPORT_DIR = "koe-diagnostics"
    private const val MAX_RETAINED_BUNDLES = 3
    private const val BUNDLE_PREFIX = "koe-diagnostics-"
    private const val BUNDLE_SUFFIX = ".json"
    private const val ERROR_STAGE_FAILED = "无法写入诊断包文件。"
    private const val ERROR_NO_SHARE_APP = "系统没有可分享诊断包的应用。"
    private const val ERROR_SHARE_DENIED = "系统未允许分享诊断包。"

    fun exportAndShare(
        store: HostSessionStore,
        diagnosticsExportRoot: File,
        shareLauncher: DiagnosticsShareLauncher?,
        nowEpochSec: Long,
        isStillBound: () -> Boolean,
    ) {
        if (!isStillBound()) return
        val payload = store.exportDiagnosticsBundleJson(nowEpochSec)
        val fileName = diagnosticsBundleFilename(nowEpochSec)
        val targetFile = try {
            writeBundleAtomically(diagnosticsExportRoot, fileName, payload).also {
                pruneOlderBundles(diagnosticsExportRoot, keep = MAX_RETAINED_BUNDLES)
            }
        } catch (error: IOException) {
            KoeLogger.w("KoeFiles", "export_diagnostics_write", "failed to stage diagnostics bundle", error.javaClass.simpleName, error)
            if (isStillBound()) store.reportNativeError(ERROR_STAGE_FAILED)
            return
        }
        if (!isStillBound()) return
        if (shareLauncher == null) {
            KoeLogger.w("KoeFiles", "export_diagnostics_share", "diagnostics share launcher unavailable", "share_launcher_missing")
            store.reportNativeError(ERROR_NO_SHARE_APP)
            return
        }
        try {
            shareLauncher.shareDiagnosticsFile(targetFile)
        } catch (error: ActivityNotFoundException) {
            KoeLogger.w("KoeFiles", "export_diagnostics_share", "no share target for diagnostics bundle", "activity_not_found", error)
            if (isStillBound()) store.reportNativeError(ERROR_NO_SHARE_APP)
        } catch (error: SecurityException) {
            KoeLogger.w("KoeFiles", "export_diagnostics_share", "share denied for diagnostics bundle", "security_exception", error)
            if (isStillBound()) store.reportNativeError(ERROR_SHARE_DENIED)
        } catch (error: IllegalArgumentException) {
            KoeLogger.w("KoeFiles", "export_diagnostics_share", "fileprovider rejected diagnostics path", error.javaClass.simpleName, error)
            if (isStillBound()) store.reportNativeError(ERROR_STAGE_FAILED)
        }
    }

    private fun writeBundleAtomically(diagnosticsExportRoot: File, fileName: String, payload: String): File {
        if (!diagnosticsExportRoot.exists() && !diagnosticsExportRoot.mkdirs()) {
            throw IOException("failed to create diagnostics staging directory")
        }
        val target = File(diagnosticsExportRoot, fileName)
        val temp = File(diagnosticsExportRoot, ".$fileName.${UUID.randomUUID()}.tmp")
        try {
            FileOutputStream(temp).use { stream ->
                stream.write(payload.toByteArray(StandardCharsets.UTF_8))
                stream.flush()
                stream.fd.sync()
            }
            try {
                Files.move(
                    temp.toPath(),
                    target.toPath(),
                    StandardCopyOption.REPLACE_EXISTING,
                    StandardCopyOption.ATOMIC_MOVE,
                )
            } catch (_: AtomicMoveNotSupportedException) {
                Files.move(
                    temp.toPath(),
                    target.toPath(),
                    StandardCopyOption.REPLACE_EXISTING,
                )
            }
            return target
        } catch (error: IOException) {
            temp.delete()
            throw error
        }
    }

    private fun pruneOlderBundles(diagnosticsExportRoot: File, keep: Int) {
        val bundles = diagnosticsExportRoot
            .listFiles { file ->
                file.isFile && file.name.startsWith(BUNDLE_PREFIX) && file.name.endsWith(BUNDLE_SUFFIX)
            }
            ?.sortedWith(compareByDescending<File> { it.lastModified() }.thenByDescending { it.name })
            ?: return
        bundles.drop(keep).forEach { stale ->
            runCatching { stale.delete() }
        }
    }
}
