package com.semanticcraft.koe.platform.capture

import android.os.SystemClock
import com.semanticcraft.koe.core.CaptureLaneSnapshot
import com.semanticcraft.koe.core.HostAdapterEvent
import com.semanticcraft.koe.core.HostCommand
import com.semanticcraft.koe.core.HostSessionStore
import com.semanticcraft.koe.core.HostSnapshot
import com.semanticcraft.koe.core.MicrophoneSnapshot
import com.semanticcraft.koe.core.PcmIngestStatus
import com.semanticcraft.koe.platform.AndroidHostAdapter

class AndroidCaptureCoordinator(
    private val source: AndroidMicrophoneSource,
    private val focusController: AudioFocusController,
    private val nowNanoseconds: () -> Long = { SystemClock.elapsedRealtimeNanos() },
    private val onForegroundStateChanged: (CaptureForegroundState) -> Unit = {},
) : AndroidHostAdapter {
    private class LaneRun(snapshot: MicrophoneSnapshot, state: CaptureLaneSnapshot) {
        val identity = CaptureIdentity.from(snapshot, LANE_MICROPHONE)
        val initialSequence = state.nextSequence
        val mailbox = MicrophoneMailbox(nextSequence = initialSequence, limit = 64)
        var fenced = false
        var pausedSent = false
        var stoppedSent = false
        var failureSent = false
    }

    private class PermissionRequest(val session: CaptureSession, val resuming: Boolean)

    private enum class DrainOutcome { DRAINED, AWAITING_SESSION_SYNC }

    private val lock = Any()
    private var boundStore: HostSessionStore? = null
    private var session: CaptureSession? = null
    private var run: LaneRun? = null
    private var pendingPermission: PermissionRequest? = null
    private var completedPermission: Pair<PermissionRequest, Boolean>? = null
    private var focusHeld = false
    private var applying = false
    private var reapplyRequested = false
    private var resumeRequested = false
    private var lastForegroundState = CaptureForegroundState(active = false, paused = false, modeTitle = null)

    override fun onSessionBound(store: HostSessionStore) {
        synchronized(lock) { boundStore = store; reapplyRequested = true }
        driveLoop()
    }

    override fun onSessionUnbound() {
        synchronized(lock) { boundStore = null; resumeRequested = false; reapplyRequested = true }
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

    fun resume() {
        synchronized(lock) { resumeRequested = true; reapplyRequested = true }
        driveLoop()
    }

    private fun driveLoop() {
        synchronized(lock) {
            if (applying) return
            applying = true
        }
        try {
            while (true) {
                val (store, completed, wantResume) = synchronized(lock) {
                    reapplyRequested = false
                    val currentStore = boundStore
                    val finishedPerm = completedPermission
                    val resumeFlag = resumeRequested
                    completedPermission = null
                    resumeRequested = false
                    Triple(currentStore, finishedPerm, resumeFlag)
                }
                if (store == null) {
                    teardownSession()
                } else {
                    if (completed != null) handleCompletedPermission(store, completed.first, completed.second)
                    if (wantResume) handleResumeRequest(store)
                    reconcile(store)
                }
                val keepGoing = synchronized(lock) {
                    val again = reapplyRequested || completedPermission != null || resumeRequested
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

    private fun teardownSession() {
        stopActiveRunAndFocus()
        synchronized(lock) {
            session = null
            run = null
            pendingPermission = null
            completedPermission = null
        }
        emitForegroundState(CaptureForegroundState(active = false, paused = false, modeTitle = null))
    }

    private fun reconcile(store: HostSessionStore) {
        val current = store.currentMicrophone()
        if (current == null) {
            teardownSession()
            return
        }
        val snapshotSession = CaptureSession.from(current)
        if (synchronized(lock) { session } != snapshotSession) {
            stopActiveRunAndFocus()
            if (current.lanes.isEmpty()) store.reportNativeError("录音快照缺少音轨，无法继续采集。")
            val laneState = current.lanes[LANE_MICROPHONE]
            val createdRun = laneState?.takeIf { !it.stopped }?.let { LaneRun(current, it) }
            synchronized(lock) {
                pendingPermission = null
                completedPermission = null
                session = snapshotSession
                run = createdRun
            }
            if (current.phase == "starting" && createdRun != null) {
                requestPermission(current, resuming = false)
            }
        }
        activeRun()?.let { reportFailure(store, it) }
        if (store.currentMicrophone()?.phase in TERMINAL_PHASES) {
            clearPendingPermission()
            stopActiveRunAndFocus()
            activeRun()?.let { reportFailure(store, it) }
        }
        if (!drainAndRefresh(store, onlyIfNonEmpty = false)) return
        if (store.currentMicrophone()?.phase in TERMINAL_PHASES) {
            clearPendingPermission()
            stopActiveRunAndFocus()
            activeRun()?.let { reportFailure(store, it) }
            if (!drainAndRefresh(store, onlyIfNonEmpty = true)) return
        }
        activeRun()?.let { finish(store, it) }
        syncForegroundState(store)
    }

    private fun drainAndRefresh(store: HostSessionStore, onlyIfNonEmpty: Boolean): Boolean {
        var maxGeneration = 0L
        val target = activeRun()
        if (target != null && (!onlyIfNonEmpty || target.mailbox.peek() != null)) {
            val outcome = drain(store, target) { gen -> if (gen > maxGeneration) maxGeneration = gen }
            if (outcome == DrainOutcome.AWAITING_SESSION_SYNC) {
                store.refreshSnapshotIfNeeded(maxGeneration)
                syncForegroundState(store)
                return false
            }
        }
        store.refreshSnapshotIfNeeded(maxGeneration)
        return true
    }

    private fun drain(store: HostSessionStore, target: LaneRun, onGeneration: (Long) -> Unit): DrainOutcome {
        var highestGeneration = 0L
        for (step in 0 until target.mailbox.limit) {
            val block = target.mailbox.peek() ?: break
            val receipt = store.ingestMicrophonePcm(
                recordId = target.identity.recordId,
                sessionId = target.identity.sessionId,
                lane = target.identity.lane,
                sequence = block.sequence,
                epoch = target.identity.epoch,
                capturedStartNs = block.pcm.capturedStartNs,
                samples = block.pcm.samples,
            )
            if (receipt.generation > highestGeneration) highestGeneration = receipt.generation
            onGeneration(receipt.generation)
            if (receipt.status == PcmIngestStatus.ACCEPTED && receipt.nextSequence == block.sequence + 1L) {
                target.mailbox.acknowledge(block.sequence)
            } else {
                store.refreshSnapshotIfNeeded(highestGeneration)
                val latest = store.currentMicrophone()
                val currentSession = synchronized(lock) { session }
                val lane = latest?.lanes?.get(target.identity.lane)
                if (latest == null || CaptureSession.from(latest) != currentSession || lane == null) {
                    return DrainOutcome.AWAITING_SESSION_SYNC
                }
                stopRunAndFocus(target)
                if (lane.error != null) return DrainOutcome.AWAITING_SESSION_SYNC
                target.mailbox.fail(store.navigation.value.effectiveError ?: "音频块未被接纳，已停止并保留此前收到的音频。")
                reportFailure(store, target)
                target.mailbox.discardUnaccepted(lane.nextSequence)
                break
            }
        }
        return DrainOutcome.DRAINED
    }

    private fun finish(store: HostSessionStore, target: LaneRun) {
        if (!target.fenced || target.mailbox.peek() != null) return
        val latest = store.currentMicrophone() ?: return
        if (CaptureSession.from(latest) != synchronized(lock) { session }) return
        val lane = latest.lanes[target.identity.lane] ?: return
        if (lane.stopped) return
        if (target.failureSent || latest.phase in STOP_PHASES) {
            if (target.stoppedSent) return
            target.stoppedSent = true
            store.send(
                HostAdapterEvent.MicrophoneStopped(
                    recordId = target.identity.recordId,
                    sessionId = target.identity.sessionId,
                    lane = target.identity.lane,
                    sequence = target.mailbox.finalSequence,
                    epoch = target.identity.epoch,
                ),
            )
        } else if (latest.phase == "pausing" && !target.pausedSent) {
            target.pausedSent = true
            store.send(
                HostAdapterEvent.MicrophonePaused(
                    recordId = target.identity.recordId,
                    sessionId = target.identity.sessionId,
                    lane = target.identity.lane,
                    sequence = target.mailbox.finalSequence,
                    epoch = target.identity.epoch,
                ),
            )
        }
    }

    private fun handleResumeRequest(store: HostSessionStore) {
        val current = store.currentMicrophone() ?: return
        val canResume = synchronized(lock) {
            current.phase == "paused" && pendingPermission == null && session == CaptureSession.from(current)
        }
        if (canResume) requestPermission(current, resuming = true)
    }

    private fun requestPermission(snapshot: MicrophoneSnapshot, resuming: Boolean) {
        val request = PermissionRequest(session = CaptureSession.from(snapshot), resuming = resuming)
        synchronized(lock) {
            pendingPermission = request
            completedPermission = null
        }
        source.requestPermission { granted ->
            val shouldDrive = synchronized(lock) {
                if (pendingPermission !== request) {
                    false
                } else {
                    pendingPermission = null
                    completedPermission = request to granted
                    reapplyRequested = true
                    !applying
                }
            }
            if (shouldDrive) driveLoop()
        }
    }

    private fun handleCompletedPermission(store: HostSessionStore, request: PermissionRequest, granted: Boolean) {
        val current = store.currentMicrophone() ?: return
        val expectedPhase = if (request.resuming) "paused" else "starting"
        if (CaptureSession.from(current) != request.session || current.phase != expectedPhase) return
        if (!granted) {
            activeRun()?.mailbox?.fail(MICROPHONE_DENIED_MESSAGE)
            return
        }
        val clock = try {
            nowNanoseconds()
        } catch (error: Throwable) {
            activeRun()?.mailbox?.fail(error.message ?: "无法读取音频采样时钟。")
            return
        }
        if (request.resuming) {
            store.send(HostAdapterEvent.ResumeMicrophone(clockNs = clock))
        } else {
            store.send(
                HostAdapterEvent.MicrophonePrepared(
                    recordId = request.session.recordId,
                    sessionId = request.session.sessionId,
                    epoch = request.session.epoch,
                    clockNs = clock,
                ),
            )
        }
        val prepared = store.currentMicrophone()
        val expectedEpoch = request.session.epoch + if (request.resuming) 1L else 0L
        val preparedPhase = if (request.resuming) "recording" else "starting"
        if (prepared == null ||
            prepared.recordId != request.session.recordId ||
            prepared.sessionId != request.session.sessionId ||
            prepared.epoch != expectedEpoch ||
            prepared.clockNs != clock ||
            prepared.phase != preparedPhase
        ) {
            activeRun()?.mailbox?.fail(store.navigation.value.effectiveError ?: "无法确认音频采样时钟。")
            return
        }
        if (request.resuming) {
            val laneState = prepared.lanes[LANE_MICROPHONE]
            val resumedRun = laneState?.takeIf { !it.stopped }?.let { LaneRun(prepared, it) }
            synchronized(lock) {
                session = CaptureSession.from(prepared)
                run = resumedRun
            }
        }
        val targetRun = activeRun() ?: return
        startRun(store, targetRun, prepared, expectedRate = prepared.lanes[LANE_MICROPHONE]?.sampleRate)
    }

    private fun startRun(store: HostSessionStore, target: LaneRun, snapshot: MicrophoneSnapshot, expectedRate: Int?) {
        val expectedSession = CaptureSession.from(snapshot)
        val focusOk = try {
            focusController.requestFocus { handleAudioFocusLost(expectedSession) }
        } catch (error: Throwable) {
            target.mailbox.fail("未能获取音频焦点：${error.message ?: "未知错误"}")
            return
        }
        if (!focusOk) {
            target.mailbox.fail("未能获取音频焦点，无法开始录音。")
            return
        }
        synchronized(lock) { focusHeld = true }
        val mailbox = target.mailbox
        try {
            val rate = source.start(
                inputId = snapshot.inputId,
                expectedSampleRate = expectedRate,
                onChunk = { pcm -> mailbox.append(pcm) },
                onFailure = { message -> mailbox.fail(message) },
            )
            if (expectedRate != null && expectedRate != rate) {
                throw IllegalStateException("麦克风采样率发生变化，已保留此前收到的音频。")
            }
            store.send(
                HostAdapterEvent.MicrophoneStarted(
                    recordId = target.identity.recordId,
                    sessionId = target.identity.sessionId,
                    lane = target.identity.lane,
                    sampleRate = rate,
                ),
            )
            val lane = store.currentMicrophone()?.lanes?.get(LANE_MICROPHONE)
            if (lane == null || !lane.started || lane.error != null) {
                mailbox.fail(store.navigation.value.effectiveError ?: "无法创建麦克风音频文件。")
            }
        } catch (error: Throwable) {
            stopRunAndFocus(target)
            mailbox.discardUnaccepted(target.initialSequence)
            val reason = error.message?.takeIf { it.isNotBlank() } ?: "未知错误"
            mailbox.fail("麦克风启动失败：$reason")
        }
    }

    private fun handleAudioFocusLost(expectedSession: CaptureSession) {
        val store = synchronized(lock) { if (session == expectedSession) boundStore else null } ?: return
        val current = store.currentMicrophone() ?: return
        if (CaptureSession.from(current) == expectedSession && current.phase == "recording") {
            store.send(HostCommand.PauseMicrophone)
        }
    }

    private fun reportFailure(store: HostSessionStore, target: LaneRun) {
        val error = target.mailbox.error ?: return
        if (target.failureSent) return
        target.failureSent = true
        stopRunAndFocus(target)
        store.send(
            HostAdapterEvent.MicrophoneFailed(
                recordId = target.identity.recordId,
                sessionId = target.identity.sessionId,
                lane = target.identity.lane,
                message = error,
                epoch = target.identity.epoch,
            ),
        )
    }

    private fun stopActiveRunAndFocus() {
        val currentRun = activeRun()
        if (currentRun != null) stopRunAndFocus(currentRun) else abandonFocusIfHeld()
    }

    private fun stopRunAndFocus(target: LaneRun) {
        if (!target.fenced) {
            source.stop()
            target.mailbox.close()
            target.fenced = true
        }
        abandonFocusIfHeld()
    }

    private fun abandonFocusIfHeld() {
        val shouldAbandon = synchronized(lock) {
            val held = focusHeld
            focusHeld = false
            held
        }
        if (shouldAbandon) focusController.abandonFocus()
    }

    private fun clearPendingPermission() {
        synchronized(lock) {
            pendingPermission = null
            completedPermission = null
        }
    }

    private fun activeRun(): LaneRun? = synchronized(lock) { run }

    private fun syncForegroundState(store: HostSessionStore) {
        val mic = store.currentMicrophone()
        val modeTitle = store.activeCapture.value?.mode?.title
        val desired = when (mic?.phase) {
            "recording" -> CaptureForegroundState(active = true, paused = false, modeTitle = modeTitle)
            "pausing", "paused" -> CaptureForegroundState(active = true, paused = true, modeTitle = modeTitle)
            else -> CaptureForegroundState(active = false, paused = false, modeTitle = null)
        }
        emitForegroundState(desired)
    }

    private fun emitForegroundState(desired: CaptureForegroundState) {
        val changed = synchronized(lock) {
            if (lastForegroundState == desired) false else { lastForegroundState = desired; true }
        }
        if (changed) onForegroundStateChanged(desired)
    }

    companion object {
        const val LANE_MICROPHONE = "microphone"
        const val MICROPHONE_DENIED_MESSAGE = "未获得麦克风权限，请在系统设置中允许 Koe 使用麦克风。"
        private val TERMINAL_PHASES = setOf("pausing", "stopping", "cancelling", "saving")
        private val STOP_PHASES = setOf("stopping", "cancelling", "saving")
    }
}
