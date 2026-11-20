package com.semanticcraft.koe.platform.files

import android.content.Context
import android.net.Uri
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import com.semanticcraft.koe.core.HostCommand
import com.semanticcraft.koe.core.HostSessionStore
import com.semanticcraft.koe.platform.AndroidHostAdapter
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.util.concurrent.Executor
import java.util.concurrent.Executors

interface DocumentPickerHost {
    fun launchOpenDocument(mimeTypes: Array<String>, onResult: (Uri?) -> Unit)
    fun launchCreateMarkdownDocument(suggestedFilename: String, onResult: (Uri?) -> Unit)
    fun launchOpenDocumentTree(onResult: (Uri?) -> Unit)
}

interface SafDocumentIo {
    fun queryDisplayName(uri: Uri): String?
    fun queryMimeType(uri: Uri): String?
    fun openInputStream(uri: Uri): InputStream?
    fun openOutputStream(uri: Uri): OutputStream?
    fun createChildMarkdownDocument(treeUri: Uri, fileName: String): Uri?
    fun deleteDocumentBestEffort(uri: Uri)
}

class SystemSafDocumentIo(
    private val context: Context,
) : SafDocumentIo {
    override fun queryDisplayName(uri: Uri): String? = runCatching {
        context.contentResolver.query(
            uri,
            arrayOf(OpenableColumns.DISPLAY_NAME),
            null,
            null,
            null,
        )?.use { cursor ->
            val index = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
            if (index >= 0 && cursor.moveToFirst() && !cursor.isNull(index)) {
                cursor.getString(index)
            } else {
                null
            }
        }
    }.getOrNull()

    override fun queryMimeType(uri: Uri): String? =
        runCatching { context.contentResolver.getType(uri) }.getOrNull()

    override fun openInputStream(uri: Uri): InputStream? =
        context.contentResolver.openInputStream(uri)

    override fun openOutputStream(uri: Uri): OutputStream? = try {
        context.contentResolver.openOutputStream(uri, "wt")
    } catch (_: IllegalArgumentException) {
        context.contentResolver.openOutputStream(uri)
    } catch (_: UnsupportedOperationException) {
        context.contentResolver.openOutputStream(uri)
    }

    override fun createChildMarkdownDocument(treeUri: Uri, fileName: String): Uri? {
        val treeDocId = DocumentsContract.getTreeDocumentId(treeUri)
        val parentDocUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, treeDocId)
        return DocumentsContract.createDocument(
            context.contentResolver,
            parentDocUri,
            MARKDOWN_MIME_TYPE,
            fileName,
        )
    }

    override fun deleteDocumentBestEffort(uri: Uri) {
        runCatching {
            DocumentsContract.deleteDocument(context.contentResolver, uri)
        }
    }

    companion object {
        const val MARKDOWN_MIME_TYPE = "text/markdown"
    }
}

class AndroidFileActions(
    private val safIo: SafDocumentIo,
    private val importStagingRoot: File,
    private val exportStagingRoot: File,
    private val ioExecutor: Executor = defaultIoExecutor(),
    private val maxImportBytes: Long = MAX_IMPORT_BYTES,
) : AndroidHostAdapter {
    constructor(context: Context) : this(
        safIo = SystemSafDocumentIo(context.applicationContext),
        importStagingRoot = File(context.cacheDir, IMPORT_STAGING_DIR),
        exportStagingRoot = File(context.cacheDir, EXPORT_STAGING_DIR),
    )

    private data class PickerLaunch(
        val store: HostSessionStore,
        val host: DocumentPickerHost,
        val token: Long,
    )

    private val lock = Any()
    private var boundStore: HostSessionStore? = null
    private var pickerHost: DocumentPickerHost? = null
    private var pickerInFlight: Boolean = false
    private var pickerToken: Long = 0L
    private var activeIoJobs: Int = 0

    fun attachActivity(host: DocumentPickerHost) {
        synchronized(lock) {
            pickerHost = host
        }
    }

    fun detachActivity(host: DocumentPickerHost) {
        synchronized(lock) {
            if (pickerHost === host) {
                pickerHost = null
                pickerInFlight = false
                pickerToken += 1L
            }
        }
    }

    override fun onSessionBound(store: HostSessionStore) {
        val shouldClean = synchronized(lock) {
            boundStore = store
            activeIoJobs == 0
        }
        if (shouldClean) {
            submitIoJob {
                val canClean = synchronized(lock) { activeIoJobs <= 1 }
                if (canClean) {
                    cleanDirectoryChildren(importStagingRoot)
                    cleanDirectoryChildren(exportStagingRoot)
                }
            }
        }
    }

    override fun onSessionUnbound() {
        synchronized(lock) {
            boundStore = null
        }
    }

    fun requestImportFile() {
        val launch = tryAcquirePickerLaunch() ?: return
        try {
            launch.host.launchOpenDocument(OPEN_DOCUMENT_MIME_TYPES) { uri ->
                if (!completePicker(launch.token) || uri == null) return@launchOpenDocument
                submitIoJob {
                    performImport(launch.store, uri)
                }
            }
        } catch (_: Throwable) {
            completePicker(launch.token)
        }
    }

    fun requestExportWorkspace(recordId: String?, date: String?, suggestedFilename: String) {
        val cleanRecordId = recordId?.trim()?.takeIf { it.isNotEmpty() }
        val cleanDate = date?.trim()?.takeIf { it.isNotEmpty() }
        if (cleanRecordId == null && cleanDate == null) return

        val safeName = sanitizeExportFileName(suggestedFilename)
        val launch = tryAcquirePickerLaunch() ?: return
        try {
            launch.host.launchCreateMarkdownDocument(safeName) { uri ->
                if (!completePicker(launch.token) || uri == null) return@launchCreateMarkdownDocument
                submitIoJob {
                    performExportWorkspace(launch.store, cleanRecordId, cleanDate, safeName, uri)
                }
            }
        } catch (_: Throwable) {
            completePicker(launch.token)
        }
    }

    fun requestExportRecords(recordIds: List<String>) {
        val cleanIds = recordIds
            .map { it.trim() }
            .filter { it.isNotEmpty() }
            .distinct()
        if (cleanIds.isEmpty()) return

        val launch = tryAcquirePickerLaunch() ?: return
        try {
            launch.host.launchOpenDocumentTree { treeUri ->
                if (!completePicker(launch.token) || treeUri == null) return@launchOpenDocumentTree
                submitIoJob {
                    performExportRecords(launch.store, cleanIds, treeUri)
                }
            }
        } catch (_: Throwable) {
            completePicker(launch.token)
        }
    }

    private fun performImport(targetStore: HostSessionStore, uri: Uri) {
        if (!isStoreBound(targetStore)) return

        val fileName = when (
            val resolved = resolveImportFileName(safIo.queryDisplayName(uri), safIo.queryMimeType(uri))
        ) {
            is ImportFileNameResult.Valid -> resolved.fileName
            ImportFileNameResult.InvalidPath -> {
                reportErrorIfBound(targetStore, ERROR_INVALID_FILE_NAME)
                return
            }
            ImportFileNameResult.UnsupportedExtension -> {
                reportErrorIfBound(targetStore, ERROR_UNSUPPORTED_EXTENSION)
                return
            }
        }

        val inputStream = try {
            safIo.openInputStream(uri)
        } catch (_: SecurityException) {
            null
        } catch (_: IOException) {
            null
        } catch (_: IllegalArgumentException) {
            null
        }
        if (inputStream == null) {
            reportErrorIfBound(targetStore, ERROR_READ_FAILED)
            return
        }

        val stageResult = try {
            inputStream.use { stream ->
                stageInputStreamToFile(
                    input = stream,
                    stagingRoot = importStagingRoot,
                    fileName = fileName,
                    maxBytes = maxImportBytes,
                )
            }
        } catch (_: SecurityException) {
            StageImportResult.IoError(ERROR_READ_FAILED)
        } catch (e: IOException) {
            StageImportResult.IoError(e.message ?: ERROR_READ_FAILED)
        }

        when (stageResult) {
            StageImportResult.TooLarge -> reportErrorIfBound(targetStore, ERROR_TOO_LARGE)
            is StageImportResult.IoError -> reportErrorIfBound(targetStore, ERROR_READ_FAILED)
            is StageImportResult.Success -> {
                try {
                    if (isStoreBound(targetStore)) {
                        targetStore.send(HostCommand.ImportFile(stageResult.file.absolutePath))
                    }
                } finally {
                    stageResult.runDir.deleteRecursively()
                }
            }
        }
    }

    private fun performExportWorkspace(
        targetStore: HostSessionStore,
        recordId: String?,
        date: String?,
        safeName: String,
        targetUri: Uri,
    ) {
        if (!isStoreBound(targetStore)) {
            safIo.deleteDocumentBestEffort(targetUri)
            return
        }

        val tempDir = try {
            createTempStagingDir(exportStagingRoot)
        } catch (_: IOException) {
            safIo.deleteDocumentBestEffort(targetUri)
            reportErrorIfBound(targetStore, ERROR_WRITE_FAILED)
            return
        }
        val tempFile = File(tempDir, safeName)
        try {
            if (!isStoreBound(targetStore)) {
                safIo.deleteDocumentBestEffort(targetUri)
                return
            }
            targetStore.send(
                HostCommand.ExportWorkspaceMarkdown(
                    recordId = recordId,
                    date = date,
                    path = tempFile.absolutePath,
                    includeAnalysis = true,
                    includeSources = true,
                ),
            )
            if (!tempFile.isFile) {
                safIo.deleteDocumentBestEffort(targetUri)
                return
            }
            if (!copyFileToUri(tempFile, targetUri)) {
                safIo.deleteDocumentBestEffort(targetUri)
                reportErrorIfBound(targetStore, ERROR_WRITE_FAILED)
            }
        } finally {
            tempDir.deleteRecursively()
        }
    }

    private fun performExportRecords(
        targetStore: HostSessionStore,
        recordIds: List<String>,
        treeUri: Uri,
    ) {
        if (!isStoreBound(targetStore)) return

        val tempDir = try {
            createTempStagingDir(exportStagingRoot)
        } catch (_: IOException) {
            reportErrorIfBound(targetStore, ERROR_BATCH_WRITE_FAILED)
            return
        }
        try {
            if (!isStoreBound(targetStore)) return
            targetStore.send(
                HostCommand.ExportRecordsMarkdown(
                    recordIds = recordIds,
                    directory = tempDir.absolutePath,
                    includeAnalysis = true,
                    includeSources = true,
                ),
            )
            val exportedFiles = tempDir.listFiles()
                ?.filter { it.isFile && it.extension.equals("md", ignoreCase = true) }
                ?.sortedBy { it.name }
                .orEmpty()
            if (exportedFiles.isEmpty()) return

            for (file in exportedFiles) {
                if (!isStoreBound(targetStore)) return
                val childUri = try {
                    safIo.createChildMarkdownDocument(treeUri, file.name)
                } catch (_: SecurityException) {
                    null
                } catch (_: IOException) {
                    null
                } catch (_: IllegalArgumentException) {
                    null
                } catch (_: UnsupportedOperationException) {
                    null
                }
                if (childUri == null) {
                    reportErrorIfBound(targetStore, ERROR_BATCH_WRITE_FAILED)
                    return
                }
                if (!copyFileToUri(file, childUri)) {
                    safIo.deleteDocumentBestEffort(childUri)
                    reportErrorIfBound(targetStore, ERROR_BATCH_WRITE_FAILED)
                    return
                }
            }
        } finally {
            tempDir.deleteRecursively()
        }
    }

    private fun copyFileToUri(source: File, targetUri: Uri): Boolean = try {
        val output = safIo.openOutputStream(targetUri) ?: return false
        output.use { out ->
            source.inputStream().use { input ->
                input.copyTo(out, COPY_BUFFER_BYTES)
            }
            out.flush()
        }
        true
    } catch (_: SecurityException) {
        false
    } catch (_: IOException) {
        false
    } catch (_: IllegalArgumentException) {
        false
    }

    private fun tryAcquirePickerLaunch(): PickerLaunch? = synchronized(lock) {
        val store = boundStore ?: return null
        val host = pickerHost ?: return null
        if (pickerInFlight) return null
        pickerInFlight = true
        pickerToken += 1L
        PickerLaunch(store = store, host = host, token = pickerToken)
    }

    private fun completePicker(token: Long): Boolean = synchronized(lock) {
        if (pickerToken == token) {
            pickerInFlight = false
            true
        } else {
            false
        }
    }

    private fun isStoreBound(targetStore: HostSessionStore): Boolean =
        synchronized(lock) { boundStore === targetStore }

    private fun reportErrorIfBound(targetStore: HostSessionStore, message: String) {
        if (isStoreBound(targetStore)) {
            targetStore.reportNativeError(message)
        }
    }

    private fun submitIoJob(block: () -> Unit) {
        synchronized(lock) {
            activeIoJobs += 1
        }
        try {
            ioExecutor.execute {
                try {
                    block()
                } finally {
                    synchronized(lock) {
                        activeIoJobs = (activeIoJobs - 1).coerceAtLeast(0)
                    }
                }
            }
        } catch (_: Throwable) {
            synchronized(lock) {
                activeIoJobs = (activeIoJobs - 1).coerceAtLeast(0)
            }
        }
    }

    private fun cleanDirectoryChildren(root: File) {
        runCatching {
            root.listFiles()?.forEach { child ->
                child.deleteRecursively()
            }
        }
    }

    companion object {
        private const val IMPORT_STAGING_DIR = "koe-saf-import"
        private const val EXPORT_STAGING_DIR = "koe-saf-export"
        private const val COPY_BUFFER_BYTES = 64 * 1024
        private val OPEN_DOCUMENT_MIME_TYPES = arrayOf("*/*")

        private const val ERROR_INVALID_FILE_NAME = "文件名无效，无法导入。"
        private const val ERROR_UNSUPPORTED_EXTENSION = "支持 WAV、TXT、Markdown 和 Koe 资料包"
        private const val ERROR_READ_FAILED = "无法读取所选文件。"
        private const val ERROR_TOO_LARGE = "请选择不超过 256 MB 的文件"
        private const val ERROR_WRITE_FAILED = "无法写入目标文件。"
        private const val ERROR_BATCH_WRITE_FAILED = "无法写入导出目录中的文件。"

        private fun defaultIoExecutor(): Executor =
            Executors.newSingleThreadExecutor { runnable ->
                Thread(runnable, "koe-saf-io").apply { isDaemon = true }
            }
    }
}
