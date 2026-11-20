package com.semanticcraft.koe.platform.capture

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build

typealias PermissionRequester = (Array<String>, (Map<String, Boolean>) -> Unit) -> Unit

class AndroidPermissionCoordinator(
    private val checkPermission: (String) -> Boolean,
) {
    private enum class Bucket {
        RECORD_AUDIO,
        BLE,
    }

    constructor(context: Context) : this(
        checkPermission = { permission ->
            context.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED
        },
    )

    private val lock = Any()
    private var activityRequester: PermissionRequester? = null
    private var activeBucket: Bucket? = null
    private val pendingByBucket = mutableMapOf<Bucket, MutableList<(Boolean) -> Unit>>()
    private val queuedBuckets = ArrayDeque<Bucket>()

    fun hasRecordAudioPermission(): Boolean = checkPermission(Manifest.permission.RECORD_AUDIO)

    fun hasBlePermissions(): Boolean = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
        checkPermission(Manifest.permission.BLUETOOTH_SCAN) &&
            checkPermission(Manifest.permission.BLUETOOTH_CONNECT)
    } else {
        checkPermission(Manifest.permission.ACCESS_FINE_LOCATION)
    }

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
            activeBucket = null
            queuedBuckets.clear()
            val snapshot = pendingByBucket.entries.map { it.key to it.value.toList() }
            pendingByBucket.clear()
            snapshot
        }
        orphaned.forEach { (bucket, callbacks) ->
            val granted = hasPermission(bucket)
            callbacks.forEach { it(granted) }
        }
    }

    fun requestRecordAudio(onResult: (Boolean) -> Unit) {
        requestBucket(Bucket.RECORD_AUDIO, onResult)
    }

    fun requestBlePermissions(onResult: (Boolean) -> Unit) {
        requestBucket(Bucket.BLE, onResult)
    }

    private fun requestBucket(bucket: Bucket, onResult: (Boolean) -> Unit) {
        if (hasPermission(bucket)) {
            onResult(true)
            return
        }
        val requesterToInvoke: PermissionRequester?
        synchronized(lock) {
            val currentRequester = activityRequester
            if (currentRequester == null) {
                requesterToInvoke = null
            } else {
                pendingByBucket.getOrPut(bucket) { mutableListOf() }.add(onResult)
                if (activeBucket == bucket) {
                    return
                }
                if (activeBucket != null) {
                    if (bucket !in queuedBuckets) {
                        queuedBuckets.addLast(bucket)
                    }
                    return
                }
                activeBucket = bucket
                requesterToInvoke = currentRequester
            }
        }
        if (requesterToInvoke == null) {
            onResult(false)
            return
        }
        launchBucket(bucket, requesterToInvoke)
    }

    private fun launchBucket(bucket: Bucket, requester: PermissionRequester) {
        val permissions = buildPermissionRequest(bucket)
        try {
            requester(permissions) { results ->
                completeBucket(bucket, evaluateResults(bucket, results))
            }
        } catch (_: Throwable) {
            completeBucket(bucket, hasPermission(bucket))
        }
    }

    private fun completeBucket(bucket: Bucket, granted: Boolean) {
        val callbacks: List<(Boolean) -> Unit>
        var nextLaunch: Pair<Bucket, PermissionRequester>? = null
        val alreadyGrantedQueued = mutableListOf<List<(Boolean) -> Unit>>()
        synchronized(lock) {
            callbacks = pendingByBucket.remove(bucket).orEmpty()
            if (activeBucket == bucket) {
                activeBucket = null
                val currentRequester = activityRequester
                while (queuedBuckets.isNotEmpty() && nextLaunch == null) {
                    val candidate = queuedBuckets.removeFirst()
                    if (hasPermission(candidate)) {
                        pendingByBucket.remove(candidate)?.let { alreadyGrantedQueued.add(it) }
                    } else if (currentRequester != null) {
                        activeBucket = candidate
                        nextLaunch = candidate to currentRequester
                    } else {
                        pendingByBucket.remove(candidate)
                    }
                }
            }
        }
        callbacks.forEach { it(granted) }
        alreadyGrantedQueued.forEach { waiting -> waiting.forEach { it(true) } }
        nextLaunch?.let { (nextBucket, requester) ->
            launchBucket(nextBucket, requester)
        }
    }

    private fun hasPermission(bucket: Bucket): Boolean = when (bucket) {
        Bucket.RECORD_AUDIO -> hasRecordAudioPermission()
        Bucket.BLE -> hasBlePermissions()
    }

    private fun buildPermissionRequest(bucket: Bucket): Array<String> = when (bucket) {
        Bucket.RECORD_AUDIO -> {
            val list = mutableListOf(Manifest.permission.RECORD_AUDIO)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
                !checkPermission(Manifest.permission.POST_NOTIFICATIONS)
            ) {
                list.add(Manifest.permission.POST_NOTIFICATIONS)
            }
            list.toTypedArray()
        }
        Bucket.BLE -> {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                arrayOf(
                    Manifest.permission.BLUETOOTH_SCAN,
                    Manifest.permission.BLUETOOTH_CONNECT,
                )
            } else {
                arrayOf(Manifest.permission.ACCESS_FINE_LOCATION)
            }
        }
    }

    private fun evaluateResults(bucket: Bucket, results: Map<String, Boolean>): Boolean = when (bucket) {
        Bucket.RECORD_AUDIO ->
            results[Manifest.permission.RECORD_AUDIO] == true || hasRecordAudioPermission()
        Bucket.BLE -> {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                val scanOk = results[Manifest.permission.BLUETOOTH_SCAN] == true ||
                    checkPermission(Manifest.permission.BLUETOOTH_SCAN)
                val connectOk = results[Manifest.permission.BLUETOOTH_CONNECT] == true ||
                    checkPermission(Manifest.permission.BLUETOOTH_CONNECT)
                scanOk && connectOk
            } else {
                results[Manifest.permission.ACCESS_FINE_LOCATION] == true ||
                    checkPermission(Manifest.permission.ACCESS_FINE_LOCATION)
            }
        }
    }
}
