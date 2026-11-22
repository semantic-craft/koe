package com.semanticcraft.koe.platform.ble

import com.semanticcraft.koe.core.KoeLogger
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

internal class CoroutineDelayScheduler(
    dispatcher: CoroutineDispatcher = Dispatchers.IO,
) {
    private val scope = CoroutineScope(SupervisorJob() + dispatcher)

    fun schedule(delayMs: Long, action: () -> Unit): AutoCloseable {
        val job = scope.launch {
            delay(delayMs.coerceAtLeast(1L))
            try {
                action()
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Throwable) {
                KoeLogger.e("KoeBle", "delayed_task", "scheduled BLE callback failed", error.javaClass.simpleName, error)
            }
        }
        return AutoCloseable { job.cancel() }
    }
}
