package com.semanticcraft.koe.platform.capture

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build

typealias PermissionRequester = (Array<String>, (Map<String, Boolean>) -> Unit) -> Unit

class AndroidPermissionCoordinator(
    private val checkPermission: (String) -> Boolean,
) {
    constructor(context: Context) : this(
        checkPermission = { permission ->
            context.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED
        },
    )

    private val lock = Any()
    private var activityRequester: PermissionRequester? = null
    private var inFlight = false
    private val pendingCallbacks = mutableListOf<(Boolean) -> Unit>()

    fun hasRecordAudioPermission(): Boolean = checkPermission(Manifest.permission.RECORD_AUDIO)

    fun attachActivity(requester: PermissionRequester) {
        synchronized(lock) {
            activityRequester = requester
        }
    }

    fun detachActivity(requester: PermissionRequester? = null) {
        val orphaned = synchronized(lock) {
            if (requester != null && activityRequester !== requester) {
                return
            }
            activityRequester = null
            if (!inFlight) {
                emptyList()
            } else {
                inFlight = false
                val waiting = pendingCallbacks.toList()
                pendingCallbacks.clear()
                waiting
            }
        }
        if (orphaned.isNotEmpty()) {
            val granted = hasRecordAudioPermission()
            orphaned.forEach { it(granted) }
        }
    }

    fun requestRecordAudio(onResult: (Boolean) -> Unit) {
        if (hasRecordAudioPermission()) {
            onResult(true)
            return
        }
        val requesterToInvoke: PermissionRequester?
        val permissionsToRequest: Array<String>?
        synchronized(lock) {
            val currentRequester = activityRequester
            if (currentRequester == null) {
                requesterToInvoke = null
                permissionsToRequest = null
            } else if (inFlight) {
                pendingCallbacks.add(onResult)
                return
            } else {
                inFlight = true
                pendingCallbacks.add(onResult)
                requesterToInvoke = currentRequester
                permissionsToRequest = buildCapturePermissionRequest()
            }
        }
        if (requesterToInvoke == null || permissionsToRequest == null) {
            onResult(false)
            return
        }
        try {
            requesterToInvoke(permissionsToRequest) { results ->
                val granted = results[Manifest.permission.RECORD_AUDIO] == true || hasRecordAudioPermission()
                completePending(granted)
            }
        } catch (_: Throwable) {
            completePending(hasRecordAudioPermission())
        }
    }

    private fun buildCapturePermissionRequest(): Array<String> {
        val list = mutableListOf(Manifest.permission.RECORD_AUDIO)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            !checkPermission(Manifest.permission.POST_NOTIFICATIONS)
        ) {
            list.add(Manifest.permission.POST_NOTIFICATIONS)
        }
        return list.toTypedArray()
    }

    private fun completePending(granted: Boolean) {
        val callbacks = synchronized(lock) {
            inFlight = false
            val waiting = pendingCallbacks.toList()
            pendingCallbacks.clear()
            waiting
        }
        callbacks.forEach { it(granted) }
    }
}
