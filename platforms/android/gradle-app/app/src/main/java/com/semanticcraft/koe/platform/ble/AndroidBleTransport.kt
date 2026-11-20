package com.semanticcraft.koe.platform.ble

import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.BluetoothStatusCodes
import android.bluetooth.le.BluetoothLeScanner
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import java.util.UUID

enum class BleAdapterState {
    SUPPORTED_READY,
    POWERED_OFF,
    UNAUTHORIZED,
    UNSUPPORTED,
}

interface BleTransportListener {
    fun onCandidateDiscovered(address: String, displayName: String)
    fun onLinkReady(address: String, displayName: String, payloadMtu: Int)
    fun onWriteCompleted(success: Boolean)
    fun onNotifyBytes(bytes: ByteArray)
    fun onDisconnected(errorMessage: String?)
}

interface BleAddressStore {
    fun read(): String?
    fun write(address: String)
    fun clear()
}

interface AndroidBleTransport {
    fun setListener(listener: BleTransportListener?)
    fun adapterState(): BleAdapterState
    fun startScan(savedAddress: String?)
    fun stopScan()
    fun connect(address: String, displayName: String)
    fun writeCharacteristic(data: ByteArray): Boolean
    fun disconnect()
}

class SharedPreferencesBleAddressStore(context: Context) : BleAddressStore {
    private val prefs = context.applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    override fun read(): String? = prefs.getString(KEY_LAST_PERIPHERAL_ADDRESS, null)?.takeIf { it.isNotBlank() }

    override fun write(address: String) {
        prefs.edit().putString(KEY_LAST_PERIPHERAL_ADDRESS, address).apply()
    }

    override fun clear() {
        prefs.edit().remove(KEY_LAST_PERIPHERAL_ADDRESS).apply()
    }

    companion object {
        const val PREFS_NAME = "koe_ble_prefs"
        const val KEY_LAST_PERIPHERAL_ADDRESS = "last_peripheral_address"
    }
}

class SystemAndroidBleTransport(
    context: Context,
    private val hasPermissions: () -> Boolean,
) : AndroidBleTransport {
    private val appContext = context.applicationContext
    private val bluetoothManager = appContext.getSystemService(BluetoothManager::class.java)
    private val lock = Any()

    @Volatile
    private var transportListener: BleTransportListener? = null
    private var activeScanner: BluetoothLeScanner? = null
    private var activeScanCallback: ScanCallback? = null
    private var activeGatt: BluetoothGatt? = null
    private var activeAddress: String? = null
    private var activeDisplayName: String? = null
    private var writeCharacteristic: BluetoothGattCharacteristic? = null
    private var payloadMtu: Int = DEFAULT_PAYLOAD_MTU
    private var servicesDiscoveryStarted: Boolean = false
    private var linkReadyReported: Boolean = false

    override fun setListener(listener: BleTransportListener?) {
        transportListener = listener
    }

    override fun adapterState(): BleAdapterState {
        if (!appContext.packageManager.hasSystemFeature(PackageManager.FEATURE_BLUETOOTH_LE)) {
            return BleAdapterState.UNSUPPORTED
        }
        val adapter = bluetoothManager?.adapter ?: return BleAdapterState.UNSUPPORTED
        if (!hasPermissions()) return BleAdapterState.UNAUTHORIZED
        return if (adapter.isEnabled) BleAdapterState.SUPPORTED_READY else BleAdapterState.POWERED_OFF
    }

    override fun startScan(savedAddress: String?) {
        if (!hasPermissions()) {
            transportListener?.onDisconnected(ERR_UNAUTHORIZED)
            return
        }
        stopScan()
        val manager = bluetoothManager
        val adapter = manager?.adapter
        if (manager == null || adapter == null || !adapter.isEnabled) {
            transportListener?.onDisconnected(ERR_POWERED_OFF)
            return
        }
        findConnectedCandidate(manager, savedAddress)?.let { (address, name) ->
            transportListener?.onCandidateDiscovered(address, name)
            return
        }
        val scanner = adapter.bluetoothLeScanner ?: run {
            transportListener?.onDisconnected(ERR_POWERED_OFF)
            return
        }
        val callback = object : ScanCallback() {
            override fun onScanResult(callbackType: Int, result: ScanResult) = handleScanResult(result, savedAddress)
            override fun onBatchScanResults(results: MutableList<ScanResult>) = results.forEach { handleScanResult(it, savedAddress) }
            override fun onScanFailed(errorCode: Int) {
                stopScan()
                transportListener?.onDisconnected("蓝牙扫描启动失败（错误码 $errorCode），请重试。")
            }
        }
        synchronized(lock) {
            activeScanner = scanner
            activeScanCallback = callback
        }
        val settings = ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).build()
        try {
            scanner.startScan(null, settings, callback)
        } catch (_: SecurityException) {
            stopScan()
            transportListener?.onDisconnected(ERR_UNAUTHORIZED)
        } catch (_: IllegalStateException) {
            stopScan()
            transportListener?.onDisconnected(ERR_POWERED_OFF)
        }
    }

    override fun stopScan() {
        val (scanner, callback) = synchronized(lock) {
            val pair = activeScanner to activeScanCallback
            activeScanner = null
            activeScanCallback = null
            pair
        }
        if (scanner != null && callback != null) {
            try {
                scanner.stopScan(callback)
            } catch (_: SecurityException) {
            } catch (_: IllegalStateException) {
            }
        }
    }

    override fun connect(address: String, displayName: String) {
        if (!hasPermissions()) {
            transportListener?.onDisconnected(ERR_UNAUTHORIZED)
            return
        }
        val adapter = bluetoothManager?.adapter
        if (adapter == null || !adapter.isEnabled || !BluetoothAdapter.checkBluetoothAddress(address)) {
            transportListener?.onDisconnected(ERR_CONNECT_FAILED)
            return
        }
        disconnect()
        val device = try {
            adapter.getRemoteDevice(address)
        } catch (_: IllegalArgumentException) {
            transportListener?.onDisconnected(ERR_CONNECT_FAILED)
            return
        }
        val error = synchronized(lock) {
            val gatt = try {
                device.connectGatt(appContext, false, gattCallback, BluetoothDevice.TRANSPORT_LE)
            } catch (_: SecurityException) {
                return@synchronized ERR_UNAUTHORIZED
            }
            if (gatt == null) {
                return@synchronized ERR_CONNECT_FAILED
            }
            activeGatt = gatt
            activeAddress = address
            activeDisplayName = displayName
            writeCharacteristic = null
            payloadMtu = DEFAULT_PAYLOAD_MTU
            servicesDiscoveryStarted = false
            linkReadyReported = false
            null
        }
        if (error != null) {
            transportListener?.onDisconnected(error)
        }
    }

    override fun writeCharacteristic(data: ByteArray): Boolean {
        val (gatt, char) = synchronized(lock) { activeGatt to writeCharacteristic }
        if (gatt == null || char == null || !hasPermissions()) return false
        val writeType = if ((char.properties and BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE) != 0) {
            BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE
        } else {
            BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
        }
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                gatt.writeCharacteristic(char, data, writeType) == BluetoothStatusCodes.SUCCESS
            } else {
                char.writeType = writeType
                char.value = data
                gatt.writeCharacteristic(char)
            }
        } catch (_: SecurityException) {
            false
        }
    }

    override fun disconnect() {
        val gatt = synchronized(lock) { clearGattStateLocked() }
        closeGattSafely(gatt)
    }

    private fun findConnectedCandidate(manager: BluetoothManager, savedAddress: String?): Pair<String, String>? {
        val devices = try {
            manager.getConnectedDevices(BluetoothProfile.GATT)
        } catch (_: SecurityException) {
            return null
        }
        for (device in devices) {
            val address = device.address ?: continue
            val name = try { device.name } catch (_: SecurityException) { null }
            val matchesSaved = savedAddress != null && address.equals(savedAddress, ignoreCase = true)
            val candidate = BleAdvertisementCandidate.match(name, null, emptyList(), emptyList())
            if (matchesSaved || candidate != null) {
                return address to (candidate?.displayName ?: name?.takeIf { it.isNotBlank() } ?: DEFAULT_NAME)
            }
        }
        return null
    }

    private fun handleScanResult(result: ScanResult, savedAddress: String?) {
        val address = result.device?.address ?: return
        val record = result.scanRecord
        val serviceUuids = buildList {
            record?.serviceUuids?.forEach { add(it.uuid.toString()) }
            record?.serviceData?.keys?.forEach { add(it.uuid.toString()) }
        }
        val manufacturerData = buildList {
            val sparse = record?.manufacturerSpecificData ?: return@buildList
            for (index in 0 until sparse.size()) {
                val companyId = sparse.keyAt(index)
                val payload = sparse.valueAt(index) ?: continue
                val wireBytes = ByteArray(payload.size + 2)
                wireBytes[0] = (companyId and 0xFF).toByte()
                wireBytes[1] = ((companyId ushr 8) and 0xFF).toByte()
                payload.copyInto(wireBytes, destinationOffset = 2)
                add(wireBytes)
            }
        }
        val deviceName = try { result.device.name } catch (_: SecurityException) { null }
        val candidate = BleAdvertisementCandidate.match(deviceName, record?.deviceName, serviceUuids, manufacturerData)
        val matchesSaved = savedAddress != null && address.equals(savedAddress, ignoreCase = true)
        if (candidate == null && !matchesSaved) return
        val displayName = candidate?.displayName
            ?: deviceName?.trim()?.takeIf { it.isNotEmpty() }
            ?: record?.deviceName?.trim()?.takeIf { it.isNotEmpty() }
            ?: DEFAULT_NAME
        transportListener?.onCandidateDiscovered(address, displayName)
    }

    private fun startServiceDiscoveryOnce(gatt: BluetoothGatt) {
        val shouldStart = synchronized(lock) {
            if (activeGatt !== gatt || servicesDiscoveryStarted) false
            else { servicesDiscoveryStarted = true; true }
        }
        if (!shouldStart) return
        val started = try { gatt.discoverServices() } catch (_: SecurityException) { false }
        if (!started) closeAndNotifyDisconnect(gatt, ERR_SERVICES_FAILED)
    }

    private fun handleCharacteristicChanged(
        gatt: BluetoothGatt,
        characteristic: BluetoothGattCharacteristic,
        value: ByteArray,
    ) {
        if (!synchronized(lock) { activeGatt === gatt && linkReadyReported }) return
        if (!isD3200NotifyCharacteristic(characteristic.uuid.toString(), characteristic.service?.uuid?.toString())) return
        transportListener?.onNotifyBytes(value.copyOf())
    }

    private fun closeAndNotifyDisconnect(gatt: BluetoothGatt, errorMessage: String?) {
        val owned = synchronized(lock) {
            if (activeGatt !== gatt) false else { clearGattStateLocked(); true }
        }
        closeGattSafely(gatt)
        if (owned) transportListener?.onDisconnected(errorMessage)
    }

    private fun clearGattStateLocked(): BluetoothGatt? {
        val gatt = activeGatt
        activeGatt = null
        activeAddress = null
        activeDisplayName = null
        writeCharacteristic = null
        payloadMtu = DEFAULT_PAYLOAD_MTU
        servicesDiscoveryStarted = false
        linkReadyReported = false
        return gatt
    }

    private fun closeGattSafely(gatt: BluetoothGatt?) {
        if (gatt == null) return
        try { gatt.disconnect() } catch (_: SecurityException) {}
        try { gatt.close() } catch (_: SecurityException) {}
    }

    private fun writeDescriptorCompat(gatt: BluetoothGatt, descriptor: BluetoothGattDescriptor, value: ByteArray): Boolean =
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                gatt.writeDescriptor(descriptor, value) == BluetoothStatusCodes.SUCCESS
            } else {
                descriptor.value = value
                gatt.writeDescriptor(descriptor)
            }
        } catch (_: SecurityException) {
            false
        }

    private val gattCallback = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
            if (!synchronized(lock) { activeGatt === gatt }) {
                closeGattSafely(gatt)
                return
            }
            if (newState == BluetoothProfile.STATE_CONNECTED && status == BluetoothGatt.GATT_SUCCESS) {
                val mtuRequested = try { gatt.requestMtu(REQUESTED_MTU) } catch (_: SecurityException) { false }
                if (!mtuRequested) startServiceDiscoveryOnce(gatt)
            } else if (newState == BluetoothProfile.STATE_DISCONNECTED || status != BluetoothGatt.GATT_SUCCESS) {
                val wasReady = synchronized(lock) { linkReadyReported }
                val error = if (status != BluetoothGatt.GATT_SUCCESS && !wasReady) ERR_CONNECT_FAILED else null
                closeAndNotifyDisconnect(gatt, error)
            }
        }

        override fun onMtuChanged(gatt: BluetoothGatt, mtu: Int, status: Int) {
            val owned = synchronized(lock) {
                if (activeGatt !== gatt) false
                else {
                    payloadMtu = if (status == BluetoothGatt.GATT_SUCCESS && mtu >= 23) mtu - 3 else DEFAULT_PAYLOAD_MTU
                    true
                }
            }
            if (owned) startServiceDiscoveryOnce(gatt)
        }

        override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
            if (!synchronized(lock) { activeGatt === gatt }) return
            if (status != BluetoothGatt.GATT_SUCCESS) {
                closeAndNotifyDisconnect(gatt, ERR_SERVICES_FAILED)
                return
            }
            var bestWrite: BluetoothGattCharacteristic? = null
            var bestWriteServiceUuid: String? = null
            var bestNotify: BluetoothGattCharacteristic? = null
            for (service in gatt.services.orEmpty()) {
                val serviceUuid = service.uuid?.toString() ?: continue
                for (characteristic in service.characteristics.orEmpty()) {
                    val charUuid = characteristic.uuid?.toString() ?: continue
                    if (isD3200WriteCharacteristic(charUuid, serviceUuid) &&
                        shouldPreferWriteCharacteristic(bestWriteServiceUuid, serviceUuid)
                    ) {
                        bestWrite = characteristic
                        bestWriteServiceUuid = serviceUuid
                    }
                    if (isD3200NotifyCharacteristic(charUuid, serviceUuid) && bestNotify == null) {
                        bestNotify = characteristic
                    }
                }
            }
            if (bestWrite == null || bestNotify == null) {
                closeAndNotifyDisconnect(gatt, ERR_NO_CHANNEL)
                return
            }
            synchronized(lock) {
                if (activeGatt !== gatt) return
                writeCharacteristic = bestWrite
            }
            val localOk = try { gatt.setCharacteristicNotification(bestNotify, true) } catch (_: SecurityException) { false }
            val cccd = bestNotify.getDescriptor(UUID.fromString(CCCD_UUID))
            if (!localOk || cccd == null || !writeDescriptorCompat(gatt, cccd, BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE)) {
                closeAndNotifyDisconnect(gatt, ERR_NOTIFY_FAILED)
            }
        }

        override fun onDescriptorWrite(gatt: BluetoothGatt, descriptor: BluetoothGattDescriptor, status: Int) {
            if (!synchronized(lock) { activeGatt === gatt }) return
            if (!descriptor.uuid.toString().equals(CCCD_UUID, ignoreCase = true)) return
            if (status != BluetoothGatt.GATT_SUCCESS) {
                closeAndNotifyDisconnect(gatt, ERR_NOTIFY_FAILED)
                return
            }
            val ready = synchronized(lock) {
                if (activeGatt !== gatt || linkReadyReported) null
                else {
                    linkReadyReported = true
                    Triple(activeAddress.orEmpty(), activeDisplayName ?: DEFAULT_NAME, payloadMtu)
                }
            } ?: return
            transportListener?.onLinkReady(ready.first, ready.second, ready.third)
        }

        override fun onCharacteristicWrite(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, status: Int) {
            if (synchronized(lock) { activeGatt === gatt }) {
                transportListener?.onWriteCompleted(status == BluetoothGatt.GATT_SUCCESS)
            }
        }

        override fun onCharacteristicChanged(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            value: ByteArray,
        ) {
            handleCharacteristicChanged(gatt, characteristic, value)
        }

        @Deprecated("Deprecated in Java")
        override fun onCharacteristicChanged(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
        ) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
                val value = characteristic.value ?: return
                handleCharacteristicChanged(gatt, characteristic, value)
            }
        }
    }

    companion object {
        private const val DEFAULT_NAME = "soundcore Work"
        private const val ERR_UNAUTHORIZED = "请在系统设置中允许 Koe 使用蓝牙。"
        private const val ERR_POWERED_OFF = "蓝牙已关闭，请在系统设置中打开。"
        private const val ERR_CONNECT_FAILED = "无法连接录音豆，请确认设备已放入充电仓并短按下方按钮。"
        private const val ERR_SERVICES_FAILED = "无法读取录音豆服务，请重新连接。"
        private const val ERR_NO_CHANNEL = "此设备没有提供支持的录音通信通道。"
        private const val ERR_NOTIFY_FAILED = "无法订阅录音豆通知，请重新连接。"
    }
}
