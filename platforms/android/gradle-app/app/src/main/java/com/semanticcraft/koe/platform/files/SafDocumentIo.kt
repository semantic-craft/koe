package com.semanticcraft.koe.platform.files

import android.content.Context
import android.net.Uri
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import com.semanticcraft.koe.core.KoeLogger
import com.semanticcraft.koe.core.WorkspaceExportOptions
import java.io.InputStream
import java.io.OutputStream

enum class PickerLaunchFailure {
    ACTIVITY_UNAVAILABLE,
    NO_PICKER_APP,
}

data class PendingPickerState(
    val kind: String,
    val recordId: String? = null,
    val date: String? = null,
    val safeName: String? = null,
    val recordIds: List<String> = emptyList(),
    val options: WorkspaceExportOptions = WorkspaceExportOptions(),
) {
    companion object {
        const val KIND_IMPORT = "import"
        const val KIND_EXPORT_WORKSPACE = "export_workspace"
        const val KIND_EXPORT_RECORDS = "export_records"
    }
}

interface DocumentPickerHost {
    fun launchOpenDocument(mimeTypes: Array<String>, onLaunchFailed: (PickerLaunchFailure) -> Unit)
    fun launchCreateMarkdownDocument(suggestedFilename: String, onLaunchFailed: (PickerLaunchFailure) -> Unit)
    fun launchOpenDocumentTree(onLaunchFailed: (PickerLaunchFailure) -> Unit)
}

interface SafDocumentIo {
    fun queryDisplayName(uri: Uri): String?
    fun queryMimeType(uri: Uri): String?
    fun queryLastModifiedMs(uri: Uri): Long? = null
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
    }.onFailure { KoeLogger.w("KoeFiles", "query_display_name", "display name query failed", error = it) }.getOrNull()

    override fun queryMimeType(uri: Uri): String? =
        runCatching { context.contentResolver.getType(uri) }
            .onFailure { KoeLogger.w("KoeFiles", "query_mime_type", "mime query failed", error = it) }
            .getOrNull()

    override fun queryLastModifiedMs(uri: Uri): Long? = runCatching {
        context.contentResolver.query(
            uri,
            arrayOf(DocumentsContract.Document.COLUMN_LAST_MODIFIED),
            null,
            null,
            null,
        )?.use { cursor ->
            val index = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_LAST_MODIFIED)
            if (index >= 0 && cursor.moveToFirst() && !cursor.isNull(index)) {
                cursor.getLong(index).takeIf { it > 0L }
            } else {
                null
            }
        }
    }.onFailure { KoeLogger.w("KoeFiles", "query_last_modified", "last modified query failed", error = it) }.getOrNull()

    override fun openInputStream(uri: Uri): InputStream? =
        context.contentResolver.openInputStream(uri)

    override fun openOutputStream(uri: Uri): OutputStream? = try {
        context.contentResolver.openOutputStream(uri, "wt")
    } catch (error: IllegalArgumentException) {
        KoeLogger.w("KoeFiles", "open_output_stream_fallback", "mode wt unsupported", "illegal_argument", error)
        context.contentResolver.openOutputStream(uri)
    } catch (error: UnsupportedOperationException) {
        KoeLogger.w("KoeFiles", "open_output_stream_fallback", "mode wt unsupported", "unsupported_operation", error)
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
        }.onFailure { KoeLogger.w("KoeFiles", "delete_document", "best-effort delete failed", error = it) }
    }

    companion object {
        const val MARKDOWN_MIME_TYPE = "text/markdown"
    }
}
