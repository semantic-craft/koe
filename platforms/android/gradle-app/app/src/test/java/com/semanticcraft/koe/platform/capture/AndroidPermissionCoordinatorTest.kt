package com.semanticcraft.koe.platform.capture

import android.Manifest
import com.semanticcraft.koe.core.HostSessionStore
import com.semanticcraft.koe.core.HostSnapshot
import com.semanticcraft.koe.platform.ble.AndroidBleCoordinator
import com.semanticcraft.koe.platform.ble.BleAdapterState
import com.semanticcraft.koe.platform.ble.BleAddressStore
import com.semanticcraft.koe.platform.ble.BleTransportListener
import com.semanticcraft.koe.platform.ble.AndroidBleTransport
import com.semanticcraft.koe.ui.KoeComposeUiTest
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
            listOf(Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT, Manifest.permission.POST_NOTIFICATIONS),
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

        var optionalNotificationDenied: Boolean? = null
        coordinator.requestBlePermissions { optionalNotificationDenied = it }
        launchedRequests.last().second(mapOf(
            Manifest.permission.BLUETOOTH_SCAN to true,
            Manifest.permission.BLUETOOTH_CONNECT to true,
            Manifest.permission.POST_NOTIFICATIONS to false,
        ))
        assertEquals(true, optionalNotificationDenied)

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

    @Test
    fun queuedBlePermissionResolvesFalseAndDoesNotWedgeBleCoordinatorWhenActivityDetaches() {
        val granted = mutableSetOf<String>()
        val coordinator = AndroidPermissionCoordinator(checkPermission = { it in granted })
        val launched = mutableListOf<Pair<List<String>, (Map<String, Boolean>) -> Unit>>()
        val requesterA: PermissionRequester = { permissions, callback ->
            launched.add(permissions.toList() to callback)
        }
        coordinator.attachActivity(requesterA)

        var scanStarts = 0
        val transport = object : AndroidBleTransport {
            override fun setListener(listener: BleTransportListener?) = Unit
            override fun adapterState(): BleAdapterState = BleAdapterState.SUPPORTED_READY
            override fun startScan(preferredAddress: String?) { scanStarts += 1 }
            override fun stopScan() = Unit
            override fun connect(address: String, displayName: String) = Unit
            override fun writeCharacteristic(bytes: ByteArray): Boolean = true
            override fun disconnect() = Unit
        }
        val addressStore = object : BleAddressStore {
            override fun read(): String? = null
            override fun write(address: String) = Unit
            override fun clear() = Unit
        }
        val bleOutcomes = mutableListOf<Boolean>()
        val bleCoordinator = AndroidBleCoordinator(
            transport = transport,
            addressStore = addressStore,
            requestBlePermission = { cb ->
                coordinator.requestBlePermissions { ok ->
                    bleOutcomes.add(ok)
                    cb(ok)
                }
            },
        )
        val store = HostSessionStore(
            "/tmp/koe-perm-detach",
            bridge = KoeComposeUiTest.FakeUiBridgeClient(HostSnapshot.empty),
        )
        bleCoordinator.onSessionBound(store)

        val micOutcomes = mutableListOf<Boolean>()
        coordinator.requestRecordAudio { ok ->
            micOutcomes.add(ok)
            coordinator.detachActivity(requesterA)
        }
        bleCoordinator.requestScan()
        assertEquals(1, launched.size)

        launched[0].second(mapOf(Manifest.permission.RECORD_AUDIO to false))
        assertEquals(listOf(false), micOutcomes)
        assertEquals(listOf(false), bleOutcomes)
        assertEquals(1, launched.size)

        val requesterB: PermissionRequester = { _, cb ->
            granted.add(Manifest.permission.BLUETOOTH_SCAN)
            granted.add(Manifest.permission.BLUETOOTH_CONNECT)
            cb(mapOf(Manifest.permission.BLUETOOTH_SCAN to true, Manifest.permission.BLUETOOTH_CONNECT to true))
        }
        coordinator.attachActivity(requesterB)
        bleCoordinator.requestScan()
        assertEquals(listOf(false, true), bleOutcomes)
        assertEquals(1, scanStarts)

        bleCoordinator.onDisconnected(null)
        granted.clear()
        val lateLaunched = mutableListOf<(Map<String, Boolean>) -> Unit>()
        val requesterC: PermissionRequester = { _, cb -> lateLaunched.add(cb) }
        coordinator.attachActivity(requesterC)
        val lateMicOutcomes = mutableListOf<Boolean>()
        coordinator.requestRecordAudio { lateMicOutcomes.add(it) }
        bleCoordinator.requestScan()
        assertEquals(1, lateLaunched.size)
        coordinator.detachActivity(requesterC)
        lateLaunched[0](mapOf(Manifest.permission.RECORD_AUDIO to true))
        assertEquals(listOf(false), lateMicOutcomes)
        assertEquals(listOf(false, true, false), bleOutcomes)
        coordinator.attachActivity(requesterB)
        bleCoordinator.requestScan()
        assertEquals(listOf(false, true, false, true), bleOutcomes)
        assertEquals(2, scanStarts)
    }

    @Test
    fun reentrantDetachAttachAndBleRequestInsideMicCallbackLaunchesNewRequesterOnce() {
        val granted = mutableSetOf<String>()
        val coordinator = AndroidPermissionCoordinator(checkPermission = { it in granted })
        val launchedA = mutableListOf<(Map<String, Boolean>) -> Unit>()
        val launchedB = mutableListOf<Pair<List<String>, (Map<String, Boolean>) -> Unit>>()
        val requesterA: PermissionRequester = { _, cb -> launchedA.add(cb) }
        val requesterB: PermissionRequester = { permissions, cb ->
            launchedB.add(permissions.toList() to cb)
        }
        coordinator.attachActivity(requesterA)

        val initialBleOutcomes = mutableListOf<Boolean>()
        val retryBleOutcomes = mutableListOf<Boolean>()
        coordinator.requestRecordAudio {
            coordinator.detachActivity(requesterA)
            coordinator.attachActivity(requesterB)
            coordinator.requestBlePermissions { retryBleOutcomes.add(it) }
        }
        coordinator.requestBlePermissions { initialBleOutcomes.add(it) }
        assertEquals(1, launchedA.size)
        assertEquals(0, launchedB.size)

        launchedA[0](mapOf(Manifest.permission.RECORD_AUDIO to false))
        assertEquals(listOf(false), initialBleOutcomes)
        assertEquals(1, launchedB.size)

        granted.add(Manifest.permission.BLUETOOTH_SCAN)
        granted.add(Manifest.permission.BLUETOOTH_CONNECT)
        launchedB[0].second(
            mapOf(
                Manifest.permission.BLUETOOTH_SCAN to true,
                Manifest.permission.BLUETOOTH_CONNECT to true,
            ),
        )
        assertEquals(listOf(true), retryBleOutcomes)
    }
}
