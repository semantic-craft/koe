package com.semanticcraft.koe.ui.screens

import android.Manifest
import android.content.ActivityNotFoundException
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.net.toUri
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.LifecycleResumeEffect
import com.semanticcraft.koe.BuildConfig
import com.semanticcraft.koe.core.AppUpdateSnapshot
import com.semanticcraft.koe.core.HostCommand
import com.semanticcraft.koe.core.HostSessionStore
import com.semanticcraft.koe.core.KoeLogger
import com.semanticcraft.koe.platform.capture.AndroidPermissionCoordinator
import com.semanticcraft.koe.ui.components.KoeCard
import com.semanticcraft.koe.ui.components.KoePrimaryButton
import com.semanticcraft.koe.ui.theme.KoeTheme
import kotlinx.serialization.json.*

@Composable
internal fun SettingsExtrasCards(store: HostSessionStore, update: AppUpdateSnapshot, supportsSelfUpdate: Boolean) {
    val context = LocalContext.current
    fun launch(intent: Intent) {
        try {
            context.startActivity(intent)
        } catch (error: ActivityNotFoundException) {
            KoeLogger.w("KoeApp", "launch_settings_intent", "no target activity", "activity_not_found", error)
            store.reportNativeError("系统没有可打开此操作的应用。")
        } catch (error: SecurityException) {
            KoeLogger.w("KoeApp", "launch_settings_intent", "intent denied", "security_exception", error)
            store.reportNativeError("系统未允许打开此操作。")
        }
    }
    KoeCard {
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            WorkspaceTitle("版本与更新")
            Text("Koe " + update.currentVersion + "（构建 " + update.currentBuild + "）")
            if (BuildConfig.ALLOW_SELF_UPDATE && supportsSelfUpdate) {
                KoePrimaryButton(if (update.isChecking) "正在检查…" else "检查更新",
                    { store.send(HostCommand.CheckAppUpdate) }, enabled = !update.isChecking)
                update.message?.takeIf { it.isNotBlank() }?.let { message ->
                    if (update.phase == "failed") {
                        Text(message, color = KoeTheme.colors.danger)
                    } else {
                        Text(message)
                    }
                }
                if (update.isUpdateAvailable) {
                    Text("新版本 " + (update.latestVersion ?: ""))
                    update.releaseNotes?.takeIf { it.isNotBlank() }?.let { Text(it) }
                    val targetUrl = update.downloadUrl?.takeIf { it.isNotBlank() } ?: update.releaseUrl
                    val uri = targetUrl.toUri()
                    if (uri.scheme == "https" && !uri.host.isNullOrBlank()) {
                        KoePrimaryButton("下载更新", { launch(Intent(Intent.ACTION_VIEW, uri)) })
                    }
                }
            } else if (!BuildConfig.ALLOW_SELF_UPDATE) Text("由 Google Play 管理更新")
        }
    }
    PermissionCard {
        launch(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", context.packageName, null)))
    }
    DiagnosticsCard {
        // Only structural metadata and the bounded command/event trace cross the share boundary.
        val report = buildJsonObject {
            put("generation", store.currentGeneration)
            put("recordCount", store.records.value.size)
            put("trace", Json.parseToJsonElement(store.exportTraceJson()))
        }
        val share = Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, report.toString())
        launch(Intent.createChooser(share, "分享诊断日志"))
    }
}

@Composable
private fun DiagnosticsCard(onExport: () -> Unit) {
    KoeCard {
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            WorkspaceTitle("诊断日志")
            Text("包含操作类型、快照代次与错误标记。")
            KoePrimaryButton("分享诊断日志", onExport, isPrimary = false)
        }
    }
}

@Composable
private fun PermissionCard(onOpenSettings: () -> Unit) {
    val context = LocalContext.current
    val coordinator = remember(context) { AndroidPermissionCoordinator(context) }
    fun readGrants() = buildList {
        add("麦克风" to coordinator.hasRecordAudioPermission())
        add("蓝牙" to coordinator.hasBlePermissions())
        if (Build.VERSION.SDK_INT >= 33) add("通知" to
            (context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED))
    }
    var grants by remember(context) { mutableStateOf(readGrants()) }
    LifecycleResumeEffect(context) {
        grants = readGrants()
        onPauseOrDispose {}
    }
    KoeCard {
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            WorkspaceTitle("系统权限")
            grants.forEach { (name, granted) -> SettingsKeyValueRow(name, if (granted) "已授权" else "未授权") }
            KoePrimaryButton("打开系统设置", onOpenSettings, isPrimary = false)
        }
    }
}
