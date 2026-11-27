package com.semanticcraft.koe.core

import kotlinx.serialization.Serializable

@Serializable
data class CaptureLaneSnapshot(
    val nextSequence: Long = 0L,
    val sampleRate: Int? = null,
    val started: Boolean = false,
    val stopped: Boolean = false,
    val error: String? = null,
    val interruption: String? = null,
)

@Serializable
data class MicrophoneSnapshot(
    val recordId: String,
    val sessionId: String,
    val lane: String,
    val inputId: String,
    val inputLabel: String = "Android 麦克风",
    val inputBadge: String = "本机",
    val phase: String = "recording",
    val nextSequence: Long = 0L,
    val durationMs: Long = 0L,
    val level: Double = 0.0,
    val error: String? = null,
    val interruption: String? = null,
    val epoch: Long = 0L,
    val clockNs: Long? = null,
    val lanes: Map<String, CaptureLaneSnapshot> = emptyMap(),
)

@Serializable
data class AudioInputSnapshot(
    val id: String,
    val sourceKey: String = "input:$id",
    val name: String = id,
    val transport: String = "external",
    val badge: String = "音频输入",
    val isDefault: Boolean = false,
)

@Serializable
data class AudioStorageSnapshot(
    val path: String,
    val totalBytes: Long = 0L,
    val fileCount: Long = 0L,
)

@Serializable
data class CaptureStudioSnapshot(
    val selectedSource: String = "system_default",
    val selectedInputId: String = "",
    val selectedLabel: String = "Android 麦克风",
    val selectedBadge: String = "本机",
    val selectionMode: String = "auto",
    val activeSource: String? = null,
    val canStart: Boolean = true,
    val inputs: List<AudioInputSnapshot> = emptyList(),
    val includeSystemAudio: Boolean = false,
    val canIncludeSystemAudio: Boolean = false,
    val audioStorage: AudioStorageSnapshot? = null,
) {
    companion object {
        val empty = CaptureStudioSnapshot()
    }
}

@Serializable
data class ActiveCaptureSnapshot(
    val mode: CaptureMode,
    val phase: String,
    val sourceLabel: String,
    val durationMs: Long = 0L,
    val actions: List<CaptureAction> = emptyList(),
    val error: String? = null,
    val level: Double? = null,
)

@Serializable
data class DeviceFileSnapshot(
    val id: Long,
    val title: String,
    val durationMs: Long = 0L,
    val synced: Boolean = false,
    val downloading: Boolean = false,
    val recordId: String? = null,
)

@Serializable
data class DeviceGuideSnapshot(
    val mode: String,
    val step: Int,
    val totalSteps: Int,
    val title: String,
    val subtitle: String,
    val imageName: String = "",
    val highlightTarget: String = "",
    val primaryLabel: String = "",
)

@Serializable
data class DeviceSnapshot(
    val phase: String = "disconnected",
    val state: String = "未连接",
    val statusDetail: String = "将麦克风放入充电仓，短按下方按钮开启广播",
    val connected: Boolean = false,
    val busy: Boolean = false,
    val recording: Boolean = false,
    val stopping: Boolean = false,
    val deviceName: String = "Soundcore Work",
    val batteryPercent: Int? = null,
    val charging: Boolean = false,
    val boxBatteryPercent: Int? = null,
    val boxCharging: Boolean = false,
    val serialNumber: String = "",
    val firmwareVersion: String = "",
    val storageLabel: String = "-",
    val storageUsedRatio: Double? = null,
    val files: List<DeviceFileSnapshot> = emptyList(),
    val progress: Double = 0.0,
    val guide: DeviceGuideSnapshot? = null,
    val transferPhase: String = "idle",
    val transferErrorCode: Int? = null,
    val audioDecryptReady: Boolean = false,
    val liveDurationMs: Long = 0L,
    val liveBytes: Long = 0L,
    val liveRecordId: String? = null,
    val autoConnect: Boolean = true,
    val explicitDisconnectCount: Long = 0L,
    val teardownStopFramesHex: List<String> = emptyList(),
) {
    companion object {
        val empty = DeviceSnapshot()
    }
}

@Serializable
data class ProviderSnapshot(
    val meetingAudioPolicy: String = "local_only",
    val meetingAudioStatus: String? = null,
    val meetingAudioPolicyError: String? = null,
    val configured: Boolean = false,
    val qwenConfigured: Boolean = false,
    val deepseekConfigured: Boolean = false,
    val asrConfigured: Boolean = false,
    val asrIsRealtime: Boolean = true,
    val asrProvider: String = "qwen",
    val asrModel: String = "qwen-audio-3.1-asr-flash-streaming",
    val llmProvider: String = "deepseek",
    val model: String = "deepseek-flash",
    val enableThinking: Boolean = false,
    val qwenWorkspaceId: String = "",
    val asrEndpoint: String = "wss://dashscope.aliyuncs.com/api-ws/v1/inference",
    val chatEndpoint: String = "https://api.deepseek.com/chat/completions",
    val defaultAsrEndpoint: String? = null,
    val defaultChatEndpoint: String? = null,
    val catalog: ProviderCatalogSnapshot? = null,
    val credentialState: String = "missing",
    val deepseekCredentialState: String = "missing",
    val isolated: Boolean = true,
) {
    val effectiveCatalog: ProviderCatalogSnapshot
        get() = catalog ?: ModelSettingsCatalog.fallback

    companion object {
        val empty = ProviderSnapshot()
    }
}

@Serializable
data class LifecycleSnapshot(
    val keepAwake: Boolean = false,
    val quitPhase: String = "running",
    val message: String? = null,
)

@Serializable
data class SpeechModelSnapshot(
    val id: String,
    val name: String,
    val sizeBytes: Long = 0L,
    val languages: List<String> = emptyList(),
    val state: String = "not_downloaded",
    val downloadedBytes: Long = 0L,
    val message: String? = null,
)

@Serializable
data class SpeechSnapshot(
    val engine: String = "apple_speech",
    val modelId: String? = null,
    val models: List<SpeechModelSnapshot> = emptyList(),
    val appleState: String = "unavailable",
    val appleMessage: String? = null,
) {
    val appleStateLabel: String
        get() = when (appleState) {
            "ready" -> "已就绪"
            "preparing" -> "准备中"
            "unavailable" -> "暂不可用"
            else -> "状态未知"
        }

    companion object {
        val empty = SpeechSnapshot()
    }
}

@Serializable
data class LiveCaptionSnapshot(
    val recordId: String,
    val text: String,
    val status: String,
)

@Serializable
data class AppUpdateSnapshot(
    val currentVersion: String = DEFAULT_VERSION,
    val currentBuild: String = DEFAULT_BUILD,
    val phase: String = "idle",
    val checkedAtEpochSec: Long? = null,
    val latestVersion: String? = null,
    val releaseTitle: String? = null,
    val publishedAt: String? = null,
    val releaseNotes: String? = null,
    val releaseUrl: String = DEFAULT_RELEASES_URL,
    val downloadUrl: String? = null,
    val assetName: String? = null,
    val assetSizeBytes: Long? = null,
    val message: String? = null,
) {
    val isChecking: Boolean get() = phase == "checking"
    val isUpdateAvailable: Boolean get() = phase == "available"

    companion object {
        const val DEFAULT_VERSION = "2.7.1"
        const val DEFAULT_BUILD = "17"
        const val DEFAULT_RELEASES_URL = "https://github.com/semantic-craft/koe/releases"
        val empty = AppUpdateSnapshot()
    }
}

@Serializable
data class PlaybackLaneSnapshot(
    val id: String,
    val available: Boolean = true,
    val interruption: String? = null,
) {
    val label: String
        get() = when (id) {
            "microphone" -> "麦克风"
            "system" -> "系统音频"
            else -> "原音频"
        }
}

@Serializable
data class PlaybackSegmentSnapshot(
    val sourceStartSample: Long,
    val sampleCount: Long,
    val timelineStartNs: Long,
)

@Serializable
data class PlaybackAssetSnapshot(
    val audioPath: String,
    val sampleRate: Int? = null,
    val durationNs: Long = 0L,
    val segments: List<PlaybackSegmentSnapshot> = emptyList(),
)

@Serializable
data class PlaybackSnapshot(
    val recordId: String? = null,
    val positionMs: Long = 0L,
    val isPlaying: Boolean = false,
    val requestId: Long = 0L,
    val lane: String? = null,
    val lanes: List<PlaybackLaneSnapshot> = emptyList(),
    val asset: PlaybackAssetSnapshot? = null,
) {
    fun updatingProgress(positionMs: Long, isPlaying: Boolean): PlaybackSnapshot =
        copy(positionMs = positionMs, isPlaying = isPlaying)

    companion object {
        val empty = PlaybackSnapshot()
    }
}
