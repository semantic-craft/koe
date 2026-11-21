package com.semanticcraft.koe.core

data class WorkspaceExportOptions(val includeAnalysis: Boolean = true, val includeSources: Boolean = true)

data class HostBridgeActions(
    val requestBleScan: () -> Unit = {},
    val flushBleOutbound: () -> Unit = {},
    val resumeMicrophone: () -> Unit = {},
    val requestImportFile: () -> Unit = {},
    val requestExportWorkspace: (recordId: String?, date: String?, suggestedFilename: String, options: WorkspaceExportOptions) -> Unit = { _, _, _, _ -> },
    val requestExportRecords: (recordIds: List<String>) -> Unit = {},
) {
    fun requestExportWorkspace(recordId: String?, date: String?, filename: String) =
        requestExportWorkspace(recordId, date, filename, WorkspaceExportOptions())
}
