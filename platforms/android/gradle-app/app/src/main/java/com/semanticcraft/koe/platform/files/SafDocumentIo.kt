package com.semanticcraft.koe.platform.files

import android.content.Context
import android.net.Uri
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import java.io.InputStream
import java.io.OutputStream

enum class PickerLaunchFailure {
    ACTIVITY_UNAVAILABLE,
    NO_PICKER_APP,
}

interface DocumentPickerHost {
    fun launchOpenDocument(mimeTypes: Array<String>, onLaunchFailed: (PickerLaunchFailure) -> Unit)
    fun launchCreateMarkdownDocument(suggestedFilename: String, onLaunchFailed: (PickerLaunchFailure) -> Unit)
    fun launchOpenDocumentTree(onLaunchFailed: (PickerLaunchFailure) -> Unit)
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
