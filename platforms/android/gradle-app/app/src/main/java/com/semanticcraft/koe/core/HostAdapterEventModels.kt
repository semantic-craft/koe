package com.semanticcraft.koe.core

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

@Serializable
data class HostAudioInputDescriptor(
    val id: String,
    val name: String,
    val transport: String,
    val isDefault: Boolean,
)

@Serializable
sealed interface HostAdapterEvent {
    fun toJsonString(): String = HostJson.json.encodeToString(serializer(), this)

    val eventType: String
        get() = when (this) {
            is SyncAudioInputs -> "sync_audio_inputs"
            is SyncAppMetadata -> "sync_app_metadata"
            is MicrophonePrepared -> "microphone_prepared"
            is ResumeMicrophone -> "resume_microphone"
            is MicrophoneStarted -> "microphone_started"
            is MicrophonePaused -> "microphone_paused"
            is MicrophoneStopped -> "microphone_stopped"
            is MicrophoneFailed -> "microphone_failed"
            is LocalAsrReadiness -> "local_asr_readiness"
            is LocalAsrResult -> "local_asr_result"
            is LocalAsrFinished -> "local_asr_finished"
            is LocalAsrFailed -> "local_asr_failed"
            is DeviceEvent -> "device_event"
            DeviceDisconnect -> "device_disconnect"
            RequestQuit -> "request_quit"
            CancelQuit -> "cancel_quit"
        }

    @Serializable @SerialName("sync_audio_inputs")
    data class SyncAudioInputs(val inputs: List<HostAudioInputDescriptor>) : HostAdapterEvent

    @Serializable @SerialName("sync_app_metadata")
    data class SyncAppMetadata(
        val version: String,
        val build: String,
        val updateEndpoint: String? = null,
        val platform: String? = null,
        val hostDisplayName: String? = null,
        val supportsSystemAudio: Boolean? = null,
        val supportsSelfUpdate: Boolean? = null,
        val nativeSpeechLabel: String? = null,
    ) : HostAdapterEvent

    @Serializable @SerialName("microphone_prepared")
    data class MicrophonePrepared(
        val recordId: String,
        val sessionId: String,
        val epoch: Long,
        val clockNs: Long,
    ) : HostAdapterEvent

    @Serializable @SerialName("resume_microphone")
    data class ResumeMicrophone(val clockNs: Long) : HostAdapterEvent

    @Serializable @SerialName("microphone_started")
    data class MicrophoneStarted(
        val recordId: String,
        val sessionId: String,
        val lane: String,
        val sampleRate: Int,
    ) : HostAdapterEvent

    @Serializable @SerialName("microphone_paused")
    data class MicrophonePaused(
        val recordId: String,
        val sessionId: String,
        val lane: String,
        val sequence: Long,
        val epoch: Long,
    ) : HostAdapterEvent

    @Serializable @SerialName("microphone_stopped")
    data class MicrophoneStopped(
        val recordId: String,
        val sessionId: String,
        val lane: String,
        val sequence: Long,
        val epoch: Long? = null,
    ) : HostAdapterEvent

    @Serializable @SerialName("microphone_failed")
    data class MicrophoneFailed(
        val recordId: String,
        val sessionId: String,
        val lane: String,
        val message: String,
        val epoch: Long? = null,
    ) : HostAdapterEvent

    @Serializable @SerialName("local_asr_readiness")
    data class LocalAsrReadiness(val state: String, val message: String) : HostAdapterEvent

    @Serializable @SerialName("local_asr_result")
    data class LocalAsrResult(
        val operationId: Long,
        val text: String,
        val startMs: Long,
        val endMs: Long,
        val isFinal: Boolean,
    ) : HostAdapterEvent

    @Serializable @SerialName("local_asr_finished")
    data class LocalAsrFinished(val operationId: Long) : HostAdapterEvent

    @Serializable @SerialName("local_asr_failed")
    data class LocalAsrFailed(val operationId: Long, val message: String) : HostAdapterEvent

    @Serializable @SerialName("device_event")
    data class DeviceEvent(
        val event: String,
        val connectionId: String,
        val deviceName: String? = null,
    ) : HostAdapterEvent

    @Serializable @SerialName("device_disconnect") data object DeviceDisconnect : HostAdapterEvent
    @Serializable @SerialName("request_quit") data object RequestQuit : HostAdapterEvent
    @Serializable @SerialName("cancel_quit") data object CancelQuit : HostAdapterEvent
}
