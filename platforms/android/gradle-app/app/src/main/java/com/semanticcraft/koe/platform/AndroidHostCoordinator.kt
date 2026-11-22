package com.semanticcraft.koe.platform

import android.os.SystemClock
import com.semanticcraft.koe.core.HostBridgeActions
import com.semanticcraft.koe.core.HostSessionStore
import com.semanticcraft.koe.core.HostSnapshot
import com.semanticcraft.koe.core.KoeLogger
import java.util.concurrent.Executor
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

interface AndroidHostAdapter {
    fun onTick(elapsedMs: Long) {}
    fun onSnapshotChanged(snapshot: HostSnapshot) {}
    fun onSessionBound(store: HostSessionStore) {}
    fun onSessionUnbound() {}
}

fun interface TickScheduler {
    fun schedulePeriodic(intervalMs: Long, onTick: () -> Unit): AutoCloseable
}

class CoroutineTickScheduler(
    dispatcher: CoroutineDispatcher = Dispatchers.IO,
) : TickScheduler {
    private val scope = CoroutineScope(SupervisorJob() + dispatcher)

    override fun schedulePeriodic(intervalMs: Long, onTick: () -> Unit): AutoCloseable {
        val periodMs = intervalMs.coerceAtLeast(1L)
        val job = scope.launch {
            while (isActive) {
                delay(periodMs)
                try {
                    onTick()
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (error: Throwable) {
                    KoeLogger.e("KoeHost", "tick", "periodic tick failed", error.javaClass.simpleName, error)
                }
            }
        }
        return AutoCloseable { job.cancel() }
    }
}

class AndroidHostCoordinator(
    private val tickIntervalMs: Long = 250L,
    private val scheduler: TickScheduler = CoroutineTickScheduler(),
    private val clockElapsedMs: () -> Long = { SystemClock.elapsedRealtime() },
    callbackExecutor: Executor? = null,
) {
    private val ownedExecutor: ExecutorService? = if (callbackExecutor == null) {
        Executors.newSingleThreadExecutor { runnable ->
            Thread(runnable, "koe-android-adapters").apply { isDaemon = true }
        }
    } else {
        null
    }
    private val adapterExecutor: Executor = callbackExecutor ?: requireNotNull(ownedExecutor)
    private val lock = Any()
    private val adapters = mutableListOf<AndroidHostAdapter>()
    private var boundStore: HostSessionStore? = null
    private var bindEpoch = 0L
    private var lastObservedPublishSequence = 0L
    private var lastDeliveredPublishSequence = 0L
    private var isShutdown = false
    private var foregroundActive = false
    private var keepAwake = false
    private var snapshotObservedForCurrentBind = false
    private var tickerDesired = false
    private var tickerEpoch = 0L
    private var activeTicker: AutoCloseable? = null
    private var lastTickMs: Long? = null

    fun registerAdapter(adapter: AndroidHostAdapter) {
        val currentStore = synchronized(lock) {
            if (adapters.any { it === adapter }) return
            adapters.add(adapter)
            boundStore
        }
        if (currentStore != null) adapter.onSessionBound(currentStore)
    }

    fun bind(store: HostSessionStore, bridgeActions: HostBridgeActions = HostBridgeActions()) {
        val previous: HostSessionStore?
        val adaptersToUnbind: List<AndroidHostAdapter>
        val adaptersToBind: List<AndroidHostAdapter>
        synchronized(lock) {
            if (boundStore === store) {
                previous = null
                adaptersToUnbind = emptyList()
                adaptersToBind = emptyList()
            } else {
                previous = boundStore
                adaptersToUnbind = if (previous != null) adapters.toList() else emptyList()
                boundStore = store
                bindEpoch += 1L
                lastObservedPublishSequence = 0L
                lastDeliveredPublishSequence = 0L
                keepAwake = false
                snapshotObservedForCurrentBind = false
                adaptersToBind = adapters.toList()
            }
        }
        if (previous != null) {
            previous.onSnapshotPublished = null
            previous.onSnapshotChanged = null
            adaptersToUnbind.forEach { it.onSessionUnbound() }
        }
        store.bridgeActions = bridgeActions
        store.onSnapshotPublished = { snapshot, publishSequence ->
            handleSnapshotChanged(store, snapshot, publishSequence)
        }
        val initialKeepAwake = store.currentLifecycle()?.keepAwake == true
        synchronized(lock) {
            if (boundStore === store && !snapshotObservedForCurrentBind) {
                keepAwake = initialKeepAwake
            }
        }
        adaptersToBind.forEach { it.onSessionBound(store) }
        reconcileTicker()
    }

    fun setForegroundActive(active: Boolean) {
        synchronized(lock) { foregroundActive = active }
        reconcileTicker()
    }

    fun tickOnce() {
        val store: HostSessionStore
        val elapsedMs: Long
        val adapterSnapshot: List<AndroidHostAdapter>
        synchronized(lock) {
            store = boundStore ?: return
            val now = clockElapsedMs()
            val previous = lastTickMs
            lastTickMs = now
            elapsedMs = if (previous == null) 0L else (now - previous).coerceAtLeast(0L)
            adapterSnapshot = adapters.toList()
        }
        store.pollTimers(elapsedMs)
        adapterSnapshot.forEach { it.onTick(elapsedMs) }
    }

    fun shutdown() {
        val previous: HostSessionStore?
        val adaptersToUnbind: List<AndroidHostAdapter>
        val handleToClose: AutoCloseable?
        synchronized(lock) {
            previous = boundStore
            adaptersToUnbind = if (previous != null) adapters.toList() else emptyList()
            boundStore = null
            bindEpoch += 1L
            lastObservedPublishSequence = 0L
            lastDeliveredPublishSequence = 0L
            isShutdown = true
            foregroundActive = false
            keepAwake = false
            snapshotObservedForCurrentBind = false
            tickerDesired = false
            tickerEpoch += 1L
            lastTickMs = null
            handleToClose = activeTicker
            activeTicker = null
        }
        handleToClose?.close()
        if (previous != null) {
            previous.onSnapshotPublished = null
            previous.onSnapshotChanged = null
            adaptersToUnbind.forEach { it.onSessionUnbound() }
        }
        ownedExecutor?.shutdown()
    }

    private fun handleSnapshotChanged(source: HostSessionStore, snapshot: HostSnapshot, publishSequence: Long) {
        val (adapterSnapshot, epoch) = synchronized(lock) {
            if (isShutdown || boundStore !== source || publishSequence <= lastObservedPublishSequence) return
            lastObservedPublishSequence = publishSequence
            snapshotObservedForCurrentBind = true
            keepAwake = snapshot.lifecycle?.keepAwake == true
            adapters.toList() to bindEpoch
        }
        reconcileTicker()
        try {
            adapterExecutor.execute {
                val shouldDeliver = synchronized(lock) {
                    if (isShutdown || boundStore !== source || bindEpoch != epoch || publishSequence <= lastDeliveredPublishSequence) {
                        false
                    } else {
                        lastDeliveredPublishSequence = publishSequence
                        true
                    }
                }
                if (shouldDeliver) adapterSnapshot.forEach { it.onSnapshotChanged(snapshot) }
            }
        } catch (error: RejectedExecutionException) {
            KoeLogger.w("KoeHost", "deliver_snapshot", "adapter executor rejected delivery", "executor_rejected", error)
        }
    }

    private fun reconcileTicker() {
        val epochToStart: Long?
        val handleToClose: AutoCloseable?
        synchronized(lock) {
            val shouldRun = boundStore != null && (foregroundActive || keepAwake)
            if (shouldRun && !tickerDesired) {
                tickerDesired = true
                tickerEpoch += 1L
                lastTickMs = clockElapsedMs()
                epochToStart = tickerEpoch
                handleToClose = null
            } else if (!shouldRun && tickerDesired) {
                tickerDesired = false
                tickerEpoch += 1L
                lastTickMs = null
                epochToStart = null
                handleToClose = activeTicker
                activeTicker = null
            } else {
                epochToStart = null
                handleToClose = null
            }
        }
        handleToClose?.close()
        if (epochToStart != null) {
            val started = scheduler.schedulePeriodic(tickIntervalMs) { tickOnce() }
            val obsolete = synchronized(lock) {
                if (tickerDesired && tickerEpoch == epochToStart) {
                    activeTicker = started
                    false
                } else {
                    true
                }
            }
            if (obsolete) started.close()
        }
    }
}
