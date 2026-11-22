package com.semanticcraft.koe.platform.ble

import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.content.Context
import androidx.test.core.app.ApplicationProvider
import com.semanticcraft.koe.core.KoeLogger
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows
import org.robolectric.annotation.Config
import org.robolectric.annotation.Implementation
import org.robolectric.annotation.Implements
import org.robolectric.shadows.ShadowBluetoothDevice

@Implements(BluetoothDevice::class)
class TestableBluetoothDeviceShadow : ShadowBluetoothDevice() {
    @Implementation
    override fun connectGatt(
        context: Context,
        autoConnect: Boolean,
        callback: BluetoothGattCallback,
        transport: Int,
    ): BluetoothGatt {
        if (throwSecurityOnConnect) {
            throw SecurityException("BLUETOOTH_CONNECT denied")
        }
        return super.connectGatt(context, autoConnect, callback, transport).also { lastCreatedGatt = it }
    }

    companion object {
        var throwSecurityOnConnect: Boolean = false
        var lastCreatedGatt: BluetoothGatt? = null
    }
}

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], shadows = [TestableBluetoothDeviceShadow::class])
class AndroidBleDiagnosticsTest {
    private val deviceAddress = "01:02:03:04:05:06"

    @Before
    fun setUp() {
        KoeLogger.clearForTests()
        KoeLogger.setSinkForTests(null)
        TestableBluetoothDeviceShadow.throwSecurityOnConnect = false
        TestableBluetoothDeviceShadow.lastCreatedGatt = null
    }

    @After
    fun tearDown() {
        TestableBluetoothDeviceShadow.throwSecurityOnConnect = false
        TestableBluetoothDeviceShadow.lastCreatedGatt = null
        KoeLogger.clearForTests()
        KoeLogger.setSinkForTests(null)
    }

    @Test
    fun connectSecurityExceptionLogsStructuredBleDiagnostic() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val manager = context.getSystemService(BluetoothManager::class.java)
        Shadows.shadowOf(manager.adapter).setState(BluetoothAdapter.STATE_ON)
        TestableBluetoothDeviceShadow.throwSecurityOnConnect = true

        val disconnectedErrors = mutableListOf<String?>()
        val transport = SystemAndroidBleTransport(context, hasPermissions = { true })
        transport.setListener(
            object : BleTransportListener {
                override fun onCandidateDiscovered(address: String, displayName: String) {}
                override fun onLinkReady(address: String, displayName: String, payloadMtu: Int) {}
                override fun onWriteCompleted(success: Boolean) {}
                override fun onNotifyBytes(bytes: ByteArray) {}
                override fun onDisconnected(errorMessage: String?) {
                    disconnectedErrors.add(errorMessage)
                }
            },
        )

        transport.connect(deviceAddress, "soundcore Work")

        assertEquals(1, disconnectedErrors.size)
        val entry = KoeLogger.recentEntries().lastOrNull { it.tag == "KoeBle" && it.operation == "connect_gatt" }
        assertNotNull("expected KoeBle connect_gatt entry", entry)
        assertEquals("SecurityException", entry?.errorCode)
        assertTrue(entry?.message?.contains("SecurityException") == true)
        assertTrue(entry?.message?.contains("BLUETOOTH_CONNECT denied") == true)
    }

    @Test
    fun gattErrorStatus133LogsExactErrorCodeInKoeLogger() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val manager = context.getSystemService(BluetoothManager::class.java)
        Shadows.shadowOf(manager.adapter).setState(BluetoothAdapter.STATE_ON)

        val disconnectedErrors = mutableListOf<String?>()
        val transport = SystemAndroidBleTransport(context, hasPermissions = { true })
        transport.setListener(
            object : BleTransportListener {
                override fun onCandidateDiscovered(address: String, displayName: String) {}
                override fun onLinkReady(address: String, displayName: String, payloadMtu: Int) {}
                override fun onWriteCompleted(success: Boolean) {}
                override fun onNotifyBytes(bytes: ByteArray) {}
                override fun onDisconnected(errorMessage: String?) {
                    disconnectedErrors.add(errorMessage)
                }
            },
        )

        transport.connect(deviceAddress, "soundcore Work")
        val gatt = checkNotNull(TestableBluetoothDeviceShadow.lastCreatedGatt)
        transport.gattCallback.onConnectionStateChange(gatt, 133, BluetoothProfile.STATE_DISCONNECTED)

        assertEquals(1, disconnectedErrors.size)
        val connEntry = KoeLogger.recentEntries().lastOrNull {
            it.tag == "KoeBle" && it.operation == "gatt_connection_state"
        }
        assertNotNull("expected KoeBle gatt_connection_state entry", connEntry)
        assertEquals("error", connEntry?.level)
        assertEquals("gatt_133", connEntry?.errorCode)
        assertTrue(connEntry?.message?.contains("133") == true)

        transport.connect(deviceAddress, "soundcore Work")
        val secondGatt = checkNotNull(TestableBluetoothDeviceShadow.lastCreatedGatt)
        transport.gattCallback.onServicesDiscovered(secondGatt, 133)

        val svcEntry = KoeLogger.recentEntries().lastOrNull {
            it.tag == "KoeBle" && it.operation == "gatt_services_discovered"
        }
        assertNotNull("expected KoeBle gatt_services_discovered entry", svcEntry)
        assertEquals("gatt_133", svcEntry?.errorCode)
    }
}
