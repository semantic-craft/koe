package com.semanticcraft.koe.platform.playback

import com.semanticcraft.koe.core.HostCommand
import com.semanticcraft.koe.core.HostSessionStore
import com.semanticcraft.koe.core.HostSnapshot
import com.semanticcraft.koe.core.PlaybackAssetSnapshot
import com.semanticcraft.koe.platform.AndroidHostAdapter
import com.semanticcraft.koe.platform.capture.AudioFocusController

class AndroidPlaybackCoordinator(
    private val sinkFactory: AudioPlaybackSinkFactory,
    private val focusController: AudioFocusController,
) : AndroidHostAdapter {
    private data class LoadedAsset(
        val recordId: String,
        val plan: PlaybackAssetSnapshot,
        val sink: AudioPlaybackSink,
    )

    private data class FailedAttempt(
        val recordId: String,
        val plan: PlaybackAssetSnapshot,
        val requestId: Long,
    )

    private val lock = Any()
    private var boundStore: HostSessionStore? = null
    private var applying = false
    private var reapplyRequested = false
    private var activeSinkToken: Any? = null

    private var loaded: LoadedAsset? = null
    private var failedAttempt: FailedAttempt? = null
    private var appliedRequestId: Long? = null
    private var lastReportedPositionMs: Long? = null
    private var focusHeld = false

    override fun onSessionBound(store: HostSessionStore) {
        synchronized(lock) {
            boundStore = store
            reapplyRequested = true
        }
        driveLoop()
    }

    override fun onSessionUnbound() {
        synchronized(lock) {
            boundStore = null
            reapplyRequested = true
        }
        driveLoop()
    }

    override fun onSnapshotChanged(snapshot: HostSnapshot) {
        synchronized(lock) { reapplyRequested = true }
        driveLoop()
    }

    override fun onTick(elapsedMs: Long) {
        synchronized(lock) { reapplyRequested = true }
        driveLoop()
    }

    private fun notifySinkStateChanged(sinkToken: Any) {
        synchronized(lock) {
            if (activeSinkToken !== sinkToken) return
            reapplyRequested = true
        }
        driveLoop()
    }

    private fun driveLoop() {
        synchronized(lock) {
            if (applying) return
            applying = true
        }
        try {
            while (true) {
                val store = synchronized(lock) {
                    reapplyRequested = false
                    boundStore
                }
                if (store == null) {
                    stopLoadedAndFocus()
                } else {
                    reconcile(store)
                }
                val keepGoing = synchronized(lock) {
                    val again = reapplyRequested
                    if (!again) applying = false
                    again
                }
                if (!keepGoing) return
            }
        } catch (error: Throwable) {
            synchronized(lock) { applying = false }
            throw error
        }
    }

    private fun reconcile(store: HostSessionStore) {
        val desired = store.playback.value
        val recordId = desired.recordId
        val plan = desired.asset
        if (recordId == null || plan == null) {
            stopLoadedAndFocus()
            return
        }

        val failed = failedAttempt
        if (failed != null &&
            failed.recordId == recordId &&
            failed.plan == plan &&
            failed.requestId == desired.requestId
        ) {
            return
        }

        val currentLoaded = loaded
        if (currentLoaded == null || currentLoaded.recordId != recordId || currentLoaded.plan != plan) {
            stopLoadedAndFocus()
            val sinkToken = Any()
            val opened = try {
                sinkFactory.open(plan) { notifySinkStateChanged(sinkToken) }
            } catch (_: Throwable) {
                fail(store, recordId, plan, desired.requestId, desired.positionMs)
                return
            }
            val latest = store.playback.value
            if (latest.recordId != recordId || latest.asset != plan) {
                runCatching { opened.close() }
                synchronized(lock) { reapplyRequested = true }
                return
            }
            synchronized(lock) { activeSinkToken = sinkToken }
            loaded = LoadedAsset(recordId, plan, opened)
        }

        val sink = loaded?.sink ?: return
        if (sink.failureMessage != null) {
            fail(store, recordId, plan, desired.requestId, desired.positionMs)
            return
        }

        var currentMs = sink.currentPositionMs
        if (appliedRequestId != desired.requestId) {
            appliedRequestId = desired.requestId
            if (currentMs != desired.positionMs) {
                if (sink.isPlaying) sink.pause()
                sink.seekToMs(desired.positionMs)
                currentMs = sink.currentPositionMs
            }
            lastReportedPositionMs = if (currentMs == desired.positionMs) currentMs else null
        }

        if (desired.isPlaying && (sink.isCompleted || currentMs >= sink.durationMs)) {
            if (sink.isPlaying) sink.pause()
            abandonFocusIfHeld()
            report(store, recordId, desired.requestId, currentMs, isPlaying = false)
            return
        }

        if (desired.isPlaying) {
            if (!ensureFocusHeld()) {
                if (sink.isPlaying) sink.pause()
                report(store, recordId, desired.requestId, currentMs, isPlaying = false)
                return
            }
            if (!sink.isPlaying) {
                sink.play()
            }
        } else {
            if (sink.isPlaying) {
                sink.pause()
            }
            abandonFocusIfHeld()
        }

        if (sink.failureMessage != null) {
            fail(store, recordId, plan, desired.requestId, desired.positionMs)
            return
        }

        currentMs = sink.currentPositionMs
        if (desired.isPlaying && sink.isCompleted) {
            if (sink.isPlaying) sink.pause()
            abandonFocusIfHeld()
            report(store, recordId, desired.requestId, currentMs, isPlaying = false)
            return
        }

        if (currentMs != lastReportedPositionMs) {
            report(store, recordId, desired.requestId, currentMs, isPlaying = desired.isPlaying)
        }
    }

    private fun ensureFocusHeld(): Boolean {
        if (focusHeld) return true
        val granted = try {
            focusController.requestFocus(::handleAudioFocusLost)
        } catch (_: Throwable) {
            false
        }
        if (granted) focusHeld = true
        return granted
    }

    private fun handleAudioFocusLost() {
        val store = synchronized(lock) { boundStore } ?: return
        if (store.playback.value.isPlaying) {
            store.send(HostCommand.Playback(isPlaying = false))
        }
    }

    private fun report(
        store: HostSessionStore,
        recordId: String,
        requestId: Long,
        positionMs: Long,
        isPlaying: Boolean,
    ) {
        lastReportedPositionMs = positionMs
        store.reportPlaybackProgress(
            recordId = recordId,
            requestId = requestId,
            positionMs = positionMs,
            isPlaying = isPlaying,
        )
    }

    private fun fail(
        store: HostSessionStore,
        recordId: String,
        plan: PlaybackAssetSnapshot,
        requestId: Long,
        positionMs: Long,
    ) {
        closeLoadedSink()
        abandonFocusIfHeld()
        failedAttempt = FailedAttempt(recordId, plan, requestId)
        report(store, recordId, requestId, positionMs, isPlaying = false)
        store.reportNativeError(PLAYBACK_ERROR_MESSAGE)
    }

    private fun stopLoadedAndFocus() {
        closeLoadedSink()
        abandonFocusIfHeld()
        failedAttempt = null
    }

    private fun closeLoadedSink() {
        synchronized(lock) { activeSinkToken = null }
        val active = loaded
        loaded = null
        appliedRequestId = null
        lastReportedPositionMs = null
        if (active != null) {
            runCatching { active.sink.close() }
        }
    }

    private fun abandonFocusIfHeld() {
        if (!focusHeld) return
        focusHeld = false
        runCatching { focusController.abandonFocus() }
    }

    companion object {
        const val PLAYBACK_ERROR_MESSAGE = "无法播放这段音频。原始文件可能不可用，或格式不受支持。"
    }
}
