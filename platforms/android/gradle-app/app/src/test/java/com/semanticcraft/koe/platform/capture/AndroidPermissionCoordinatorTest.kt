package com.semanticcraft.koe.platform.capture

import android.Manifest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class AndroidPermissionCoordinatorTest {
    @Test
    fun returnsTrueSynchronouslyWhenAlreadyGrantedAndFalseWhenDetached() {
        val grantedCoordinator = AndroidPermissionCoordinator(checkPermission = { true })
        var syncResult: Boolean? = null
        grantedCoordinator.requestRecordAudio { syncResult = it }
        assertEquals(true, syncResult)

        val deniedCoordinator = AndroidPermissionCoordinator(checkPermission = { false })
        var detachedResult: Boolean? = null
        deniedCoordinator.requestRecordAudio { detachedResult = it }
        assertEquals(false, detachedResult)
    }

    @Test
    fun requestsNotificationsOnApi33PlusCoalescesConcurrentCallersAndCompletesOnDetach() {
        val coordinator = AndroidPermissionCoordinator(checkPermission = { false })
        var launchedPermissions: List<String>? = null
        var pendingCallback: ((Map<String, Boolean>) -> Unit)? = null
        var launchCount = 0
        val requesterA: PermissionRequester = { permissions, callback ->
            launchCount += 1
            launchedPermissions = permissions.toList()
            pendingCallback = callback
        }
        coordinator.attachActivity(requesterA)

        val outcomes = mutableListOf<Boolean>()
        coordinator.requestRecordAudio { outcomes.add(it) }
        coordinator.requestRecordAudio { outcomes.add(it) }
        assertEquals(1, launchCount)
        assertEquals(
            listOf(Manifest.permission.RECORD_AUDIO, Manifest.permission.POST_NOTIFICATIONS),
            launchedPermissions,
        )

        pendingCallback!!.invoke(
            mapOf(
                Manifest.permission.RECORD_AUDIO to true,
                Manifest.permission.POST_NOTIFICATIONS to false,
            ),
        )
        assertEquals(listOf(true, true), outcomes)

        var orphanedOutcome: Boolean? = null
        coordinator.requestRecordAudio { orphanedOutcome = it }
        val requesterB: PermissionRequester = { _, cb -> cb(mapOf(Manifest.permission.RECORD_AUDIO to true)) }
        coordinator.attachActivity(requesterB)
        coordinator.detachActivity(requesterA)
        assertEquals(null, orphanedOutcome)

        coordinator.detachActivity(requesterB)
        assertEquals(false, orphanedOutcome)
        assertFalse(coordinator.hasRecordAudioPermission())
    }
}
