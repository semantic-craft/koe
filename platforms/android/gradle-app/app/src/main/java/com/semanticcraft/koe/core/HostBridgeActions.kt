package com.semanticcraft.koe.core

data class HostBridgeActions(
    val requestBleScan: () -> Unit = {},
    val flushBleOutbound: () -> Unit = {},
    val resumeMicrophone: () -> Unit = {},
    val requestImportFile: () -> Unit = {},
    val requestExportWorkspace: (recordId: String?, date: String?, suggestedFilename: String) -> Unit = { _, _, _ -> },
    val requestExportRecords: (recordIds: List<String>) -> Unit = {},
)
