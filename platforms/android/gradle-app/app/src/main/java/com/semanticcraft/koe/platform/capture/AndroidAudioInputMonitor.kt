package com.semanticcraft.koe.platform.capture

import android.content.Context
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import com.semanticcraft.koe.core.HostAdapterEvent
import com.semanticcraft.koe.core.HostAudioInputDescriptor
import com.semanticcraft.koe.core.HostSessionStore
import com.semanticcraft.koe.platform.AndroidHostAdapter

interface AudioInputProvider {
    fun listInputs(): List<HostAudioInputDescriptor>

    fun registerListener(onChanged: () -> Unit): AutoCloseable
}

internal fun mapAudioDeviceTransport(type: Int): String = when {
    type == AudioDeviceInfo.TYPE_BUILTIN_MIC -> "built_in"
    type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO ||
        type == AudioDeviceInfo.TYPE_BLUETOOTH_A2DP ||
        (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && type == AudioDeviceInfo.TYPE_BLE_HEADSET) -> "bluetooth"
    type == AudioDeviceInfo.TYPE_USB_DEVICE ||
        type == AudioDeviceInfo.TYPE_USB_ACCESSORY ||
        type == AudioDeviceInfo.TYPE_USB_HEADSET -> "usb"
    else -> "external"
}

private fun isRecordableInputDeviceType(type: Int): Boolean =
    type != AudioDeviceInfo.TYPE_TELEPHONY &&
        (Build.VERSION.SDK_INT < Build.VERSION_CODES.S || type != AudioDeviceInfo.TYPE_REMOTE_SUBMIX) &&
        type != AudioDeviceInfo.TYPE_FM_TUNER &&
        type != AudioDeviceInfo.TYPE_TV_TUNER

private fun fallbackNameForTransport(transport: String): String = when (transport) {
    "built_in" -> "内置麦克风"
    "bluetooth" -> "蓝牙麦克风"
    "usb" -> "USB 麦克风"
    else -> "外部麦克风"
}

class SystemAudioInputProvider(
    context: Context,
) : AudioInputProvider {
    private val audioManager = context.getSystemService(AudioManager::class.java)
    private val callbackHandler = Handler(Looper.getMainLooper())

    override fun listInputs(): List<HostAudioInputDescriptor> {
        val manager = audioManager ?: return emptyList()
        val rawDevices = manager.getDevices(AudioManager.GET_DEVICES_INPUTS)
            .filter { it.isSource && isRecordableInputDeviceType(it.type) }
            .take(MAX_AUDIO_INPUTS)
        val defaultId = rawDevices.firstOrNull { it.type == AudioDeviceInfo.TYPE_BUILTIN_MIC }?.id
            ?: rawDevices.firstOrNull()?.id
        return rawDevices.map { device ->
            val transport = mapAudioDeviceTransport(device.type)
            val label = device.productName?.toString()?.trim().orEmpty()
            HostAudioInputDescriptor(
                id = device.id.toString(),
                name = if (label.isNotEmpty()) label else fallbackNameForTransport(transport),
                transport = transport,
                isDefault = device.id == defaultId,
            )
        }
    }

    override fun registerListener(onChanged: () -> Unit): AutoCloseable {
        val manager = audioManager ?: return AutoCloseable {}
        val callback = object : AudioDeviceCallback() {
            override fun onAudioDevicesAdded(addedDevices: Array<out AudioDeviceInfo>?) {
                onChanged()
            }

            override fun onAudioDevicesRemoved(removedDevices: Array<out AudioDeviceInfo>?) {
                onChanged()
            }
        }
        manager.registerAudioDeviceCallback(callback, callbackHandler)
        var closed = false
        return AutoCloseable {
            if (!closed) {
                closed = true
                manager.unregisterAudioDeviceCallback(callback)
            }
        }
    }

    companion object {
        private const val MAX_AUDIO_INPUTS = 64
    }
}

class AndroidAudioInputMonitor(
    private val provider: AudioInputProvider,
) : AndroidHostAdapter {
    constructor(context: Context) : this(SystemAudioInputProvider(context))

    private val lock = Any()
    private var boundStore: HostSessionStore? = null
    private var registration: AutoCloseable? = null
    private var lastSynced: List<HostAudioInputDescriptor>? = null

    override fun onSessionBound(store: HostSessionStore) {
        val previousRegistration = synchronized(lock) {
            boundStore = store
            lastSynced = null
            val prev = registration
            registration = null
            prev
        }
        previousRegistration?.close()
        val nextRegistration = provider.registerListener { syncInputs() }
        val shouldClose = synchronized(lock) {
            if (boundStore === store) {
                registration = nextRegistration
                false
            } else {
                true
            }
        }
        if (shouldClose) {
            nextRegistration.close()
            return
        }
        syncInputs()
    }

    override fun onSessionUnbound() {
        val handle = synchronized(lock) {
            boundStore = null
            lastSynced = null
            val existing = registration
            registration = null
            existing
        }
        handle?.close()
    }

    fun syncInputs() {
        val store = synchronized(lock) { boundStore } ?: return
        val inputs = provider.listInputs()
        val shouldDispatch = synchronized(lock) {
            if (boundStore !== store || lastSynced == inputs) {
                false
            } else {
                lastSynced = inputs
                true
            }
        }
        if (shouldDispatch) {
            store.send(HostAdapterEvent.SyncAudioInputs(inputs))
        }
    }
}
