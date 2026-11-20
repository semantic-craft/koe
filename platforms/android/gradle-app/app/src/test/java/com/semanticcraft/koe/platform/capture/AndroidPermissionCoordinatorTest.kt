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

    @Test
    fun recordAudioAndBlePermissionBucketsStayIndependentAndSerializeLauncher() {
        val granted = mutableSetOf<String>()
        val coordinator = AndroidPermissionCoordinator(checkPermission = { it in granted })
        val launchedRequests = mutableListOf<Pair<List<String>, (Map<String, Boolean>) -> Unit>>()
        val requester: PermissionRequester = { permissions, callback ->
            launchedRequests.add(permissions.toList() to callback)
        }
        coordinator.attachActivity(requester)

        val audioOutcomes = mutableListOf<Boolean>()
        val bleOutcomes = mutableListOf<Boolean>()
        coordinator.requestRecordAudio { audioOutcomes.add(it) }
        coordinator.requestBlePermissions { bleOutcomes.add(it) }
        coordinator.requestBlePermissions { bleOutcomes.add(it) }

        assertEquals(1, launchedRequests.size)
        assertEquals(
            listOf(Manifest.permission.RECORD_AUDIO, Manifest.permission.POST_NOTIFICATIONS),
            launchedRequests[0].first,
        )

        granted.add(Manifest.permission.RECORD_AUDIO)
        launchedRequests[0].second.invoke(
            mapOf(
                Manifest.permission.RECORD_AUDIO to true,
                Manifest.permission.POST_NOTIFICATIONS to false,
            ),
        )
        assertEquals(listOf(true), audioOutcomes)
        assertTrue(bleOutcomes.isEmpty())
        assertEquals(2, launchedRequests.size)
        assertEquals(
            listOf(Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT),
            launchedRequests[1].first,
        )

        granted.add(Manifest.permission.BLUETOOTH_SCAN)
        launchedRequests[1].second.invoke(
            mapOf(
                Manifest.permission.BLUETOOTH_SCAN to true,
                Manifest.permission.BLUETOOTH_CONNECT to false,
            ),
        )
        assertEquals(listOf(false, false), bleOutcomes)
        assertFalse(coordinator.hasBlePermissions())

        granted.add(Manifest.permission.BLUETOOTH_CONNECT)
        assertTrue(coordinator.hasBlePermissions())
        var syncBleGrant: Boolean? = null
        coordinator.requestBlePermissions { syncBleGrant = it }
        assertEquals(true, syncBleGrant)
    }

    @Test
    @Config(sdk = [30])
    fun blePermissionsUseFineLocationOnApi30() {
        val granted = mutableSetOf<String>()
        val coordinator = AndroidPermissionCoordinator(checkPermission = { it in granted })
        var launchedPermissions: List<String>? = null
        val requester: PermissionRequester = { permissions, callback ->
            launchedPermissions = permissions.toList()
            granted.add(Manifest.permission.ACCESS_FINE_LOCATION)
            callback(mapOf(Manifest.permission.ACCESS_FINE_LOCATION to true))
        }
        coordinator.attachActivity(requester)

        var outcome: Boolean? = null
        coordinator.requestBlePermissions { outcome = it }
        assertEquals(listOf(Manifest.permission.ACCESS_FINE_LOCATION), launchedPermissions)
        assertEquals(true, outcome)
        assertTrue(coordinator.hasBlePermissions())
    }
}
