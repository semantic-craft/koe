package com.semanticcraft.koe.platform.files

import android.content.ActivityNotFoundException
import android.content.Context
import android.net.Uri
import com.semanticcraft.koe.core.HostCommand
import com.semanticcraft.koe.core.HostSessionStore
import com.semanticcraft.koe.core.WorkspaceExportOptions
import com.semanticcraft.koe.platform.AndroidHostAdapter
import java.io.File
import java.io.IOException
import java.util.concurrent.Executor
import java.util.concurrent.Executors

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

    private sealed interface PendingPickerRequest {
        val store: HostSessionStore
        class Import(override val store: HostSessionStore) : PendingPickerRequest
        class ExportWorkspace(
            override val store: HostSessionStore,
            val recordId: String?,
            val date: String?,
            val safeName: String,
            val options: WorkspaceExportOptions,
        ) : PendingPickerRequest
        class ExportRecords(override val store: HostSessionStore, val recordIds: List<String>) : PendingPickerRequest
    }

    private val lock = Any()
    private var boundStore: HostSessionStore? = null
    private var pickerHost: DocumentPickerHost? = null
    private var pendingRequest: PendingPickerRequest? = null
    private var activeIoJobs: Int = 0

    fun attachActivity(host: DocumentPickerHost) {
        synchronized(lock) {
            pickerHost = host
        }
    }

    fun detachActivity(host: DocumentPickerHost, keepPendingRequest: Boolean = false) {
        synchronized(lock) {
            if (pickerHost === host) {
                pickerHost = null
                if (!keepPendingRequest) {
                    pendingRequest = null
                }
            }
        }
    }

    fun exportPendingState(): PendingPickerState? = synchronized(lock) {
        when (val current = pendingRequest) {
            null -> null
            is PendingPickerRequest.Import -> PendingPickerState(kind = PendingPickerState.KIND_IMPORT)
            is PendingPickerRequest.ExportWorkspace -> PendingPickerState(
                kind = PendingPickerState.KIND_EXPORT_WORKSPACE,
                recordId = current.recordId,
                date = current.date,
                safeName = current.safeName,
                options = current.options,
            )
            is PendingPickerRequest.ExportRecords -> PendingPickerState(
                kind = PendingPickerState.KIND_EXPORT_RECORDS,
                recordIds = current.recordIds,
            )
        }
    }

    fun restorePendingState(state: PendingPickerState?) {
        if (state == null) return
        synchronized(lock) {
            if (pendingRequest != null) return
            val store = boundStore ?: return
            pendingRequest = when (state.kind) {
                PendingPickerState.KIND_IMPORT -> PendingPickerRequest.Import(store)
                PendingPickerState.KIND_EXPORT_WORKSPACE -> {
                    val cleanRecordId = state.recordId?.trim()?.takeIf { it.isNotEmpty() }
                    val cleanDate = state.date?.trim()?.takeIf { it.isNotEmpty() }
                    if (cleanRecordId == null && cleanDate == null) return
                    PendingPickerRequest.ExportWorkspace(
                        store = store,
                        recordId = cleanRecordId,
                        date = cleanDate,
                        safeName = sanitizeExportFileName(state.safeName),
                        options = state.options,
                    )
                }
                PendingPickerState.KIND_EXPORT_RECORDS -> {
                    val cleanIds = normalizeRecordIds(state.recordIds)
                    if (cleanIds.isEmpty()) return
                    PendingPickerRequest.ExportRecords(store, cleanIds)
                }
                else -> null
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
            pendingRequest = null
        }
    }

    fun requestImportFile() {
        launchPicker(
            requestFactory = { store -> PendingPickerRequest.Import(store) },
            launch = { host, request ->
                host.launchOpenDocument(OPEN_DOCUMENT_MIME_TYPES) { failure ->
                    handleLaunchFailed(request, failure)
                }
            },
        )
    }

    fun requestExportWorkspace(recordId: String?, date: String?, suggestedFilename: String,
                               options: WorkspaceExportOptions = WorkspaceExportOptions()) {
        val cleanRecordId = recordId?.trim()?.takeIf { it.isNotEmpty() }
        val cleanDate = date?.trim()?.takeIf { it.isNotEmpty() }
        if (cleanRecordId == null && cleanDate == null) return

        val safeName = sanitizeExportFileName(suggestedFilename)
        launchPicker(
            requestFactory = { store ->
                PendingPickerRequest.ExportWorkspace(store, cleanRecordId, cleanDate, safeName, options)
            },
            launch = { host, request ->
                host.launchCreateMarkdownDocument(safeName) { failure ->
                    handleLaunchFailed(request, failure)
                }
            },
        )
    }

    fun requestExportRecords(recordIds: List<String>) {
        val cleanIds = normalizeRecordIds(recordIds)
        if (cleanIds.isEmpty()) return

        launchPicker(
            requestFactory = { store -> PendingPickerRequest.ExportRecords(store, cleanIds) },
            launch = { host, request ->
                host.launchOpenDocumentTree { failure ->
                    handleLaunchFailed(request, failure)
                }
            },
        )
    }

    fun onOpenDocumentResult(uri: Uri?) {
        val request = synchronized(lock) {
            val current = pendingRequest as? PendingPickerRequest.Import ?: return
            pendingRequest = null
            current
        }
        if (uri == null) return
        submitIoJob {
            performImport(request.store, uri)
        }
    }

    fun onCreateMarkdownResult(uri: Uri?) {
        val request = synchronized(lock) {
            val current = pendingRequest as? PendingPickerRequest.ExportWorkspace
            if (current != null) {
                pendingRequest = null
            }
            current
        }
        if (request == null) {
            if (uri != null) {
                submitIoJob { safIo.deleteDocumentBestEffort(uri) }
            }
            return
        }
        if (uri == null) return
        submitIoJob { performExportWorkspace(request, uri) }
    }

    fun onOpenDocumentTreeResult(treeUri: Uri?) {
        val request = synchronized(lock) {
            val current = pendingRequest as? PendingPickerRequest.ExportRecords ?: return
            pendingRequest = null
            current
        }
        if (treeUri == null) return
        submitIoJob {
            performExportRecords(request.store, request.recordIds, treeUri)
        }
    }

    private fun launchPicker(
        requestFactory: (HostSessionStore) -> PendingPickerRequest,
        launch: (DocumentPickerHost, PendingPickerRequest) -> Unit,
    ) {
        val (host, request) = synchronized(lock) {
            val store = boundStore ?: return
            val activeHost = pickerHost ?: return
            if (pendingRequest != null) return
            val created = requestFactory(store)
            pendingRequest = created
            activeHost to created
        }
        try {
            launch(host, request)
        } catch (_: ActivityNotFoundException) {
            handleLaunchFailed(request, PickerLaunchFailure.NO_PICKER_APP)
        } catch (_: Throwable) {
            handleLaunchFailed(request, PickerLaunchFailure.ACTIVITY_UNAVAILABLE)
        }
    }

    private fun handleLaunchFailed(request: PendingPickerRequest, failure: PickerLaunchFailure) {
        val cleared = synchronized(lock) {
            if (pendingRequest === request) {
                pendingRequest = null
                true
            } else {
                false
            }
        }
        if (cleared && failure == PickerLaunchFailure.NO_PICKER_APP) {
            reportErrorIfBound(request.store, ERROR_NO_PICKER_APP)
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

        val lastModifiedMs = safIo.queryLastModifiedMs(uri)
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
                    lastModifiedMs = lastModifiedMs,
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
                        targetStore.sendReturningError(HostCommand.ImportFile(stageResult.file.absolutePath))
                            ?.let { reportErrorIfBound(targetStore, it) }
                    }
                } finally {
                    stageResult.runDir.deleteRecursively()
                }
            }
        }
    }

    private fun performExportWorkspace(request: PendingPickerRequest.ExportWorkspace, targetUri: Uri) {
        val targetStore = request.store
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
        val tempFile = File(tempDir, request.safeName)
        try {
            if (!isStoreBound(targetStore)) {
                safIo.deleteDocumentBestEffort(targetUri)
                return
            }
            val error = targetStore.sendReturningError(
                HostCommand.ExportWorkspaceMarkdown(
                    recordId = request.recordId,
                    date = request.date,
                    path = tempFile.absolutePath,
                    includeAnalysis = request.options.includeAnalysis,
                    includeSources = request.options.includeSources,
                ),
            )
            if (error != null || !tempFile.isFile) {
                reportErrorIfBound(targetStore, error ?: ERROR_WRITE_FAILED)
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
            val error = targetStore.sendReturningError(
                HostCommand.ExportRecordsMarkdown(
                    recordIds = recordIds,
                    directory = tempDir.absolutePath,
                    includeAnalysis = true,
                    includeSources = true,
                ),
            )
            if (error != null) return reportErrorIfBound(targetStore, error)
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

    private fun normalizeRecordIds(recordIds: List<String>): List<String> =
        recordIds.map { it.trim() }.filter { it.isNotEmpty() }.distinct()

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

        private const val ERROR_NO_PICKER_APP = "系统未找到可用的文件选择器。"
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
