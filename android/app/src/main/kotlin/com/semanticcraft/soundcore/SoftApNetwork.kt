package com.semanticcraft.soundcore

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.WifiManager
import android.net.wifi.WifiNetworkSpecifier
import android.os.Handler
import android.os.Looper
import android.util.Log
import java.io.Closeable
import java.io.IOException
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

/**
 * Puts Koe on the recorder's Wi-Fi hotspot for an export (PROTOCOL.md §6.4).
 *
 * The hotspot has no internet, so Android joins it beside the phone's own
 * network rather than in its place, and only sockets bound to it reach the
 * recorder. Dart cannot bind its sockets to a network, so the WebSocket runs
 * through a one-connection loopback tunnel and the UDP keepalive is sent from
 * here; the rest of Koe (transcription, analysis) keeps the default network.
 */
class SoftApNetwork private constructor(context: Context) {
    private val connectivity = context.getSystemService(ConnectivityManager::class.java)
    private val wifi = context.getSystemService(WifiManager::class.java)
    private val mainThread = Handler(Looper.getMainLooper())
    private val io = Executors.newCachedThreadPool()

    @Volatile private var network: Network? = null
    private var callback: ConnectivityManager.NetworkCallback? = null
    private var answerJoin: ((String?) -> Unit)? = null
    private val tunnelSockets = CopyOnWriteArrayList<Closeable>()
    private var keepalive: ScheduledExecutorService? = null
    private var keepaliveSocket: DatagramSocket? = null

    /**
     * Asks Android to join [ssid]. The system shows its own "connect to
     * device" dialog; [done] gets null once joined, or why not: "wifi_off",
     * "unavailable" when the user declined or the hotspot never showed up
     * within [timeoutMs], or "cancelled" when [release] came first.
     */
    fun join(ssid: String, password: String, timeoutMs: Int, done: (String?) -> Unit) {
        release()
        if (!wifi.isWifiEnabled) {
            done("wifi_off")
            return
        }
        val answered = AtomicBoolean(false)
        fun answer(error: String?) {
            if (answered.compareAndSet(false, true)) mainThread.post { done(error) }
        }
        answerJoin = ::answer
        // The recorder may hide its SSID; a hidden-SSID request probes for it
        // by name, which finds a visible one too.
        val specifier = WifiNetworkSpecifier.Builder()
            .setSsid(ssid)
            .setWpa2Passphrase(password)
            .setIsHiddenSsid(true)
            .build()
        val request = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            .removeCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .setNetworkSpecifier(specifier)
            .build()
        val joined = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(available: Network) {
                network = available
                answer(null)
            }

            override fun onUnavailable() {
                answer("unavailable")
            }

            override fun onLost(lost: Network) {
                if (network == lost) network = null
            }
        }
        callback = joined
        connectivity.requestNetwork(request, joined, timeoutMs)
    }

    /**
     * Connects to [host]:[port] over the joined hotspot and returns a
     * loopback port whose first connection is piped to it. The recorder's
     * single WebSocket listener is taken as soon as this returns, so the
     * tunnel gives up if nothing connects within a few seconds.
     */
    fun openTunnel(host: String, port: Int, done: (Int?, String?) -> Unit) {
        val joined = network
        if (joined == null) {
            done(null, "not_joined")
            return
        }
        io.execute {
            var remote: Socket? = null
            var server: ServerSocket? = null
            try {
                remote = joined.socketFactory.createSocket().apply {
                    tcpNoDelay = true
                    connect(InetSocketAddress(host, port), CONNECT_TIMEOUT_MS)
                }
                // Dart dials 127.0.0.1; getLoopbackAddress() may be ::1.
                server = ServerSocket(0, 1, InetAddress.getByAddress(byteArrayOf(127, 0, 0, 1))).apply {
                    soTimeout = ACCEPT_TIMEOUT_MS
                }
                tunnelSockets += remote
                tunnelSockets += server
                val localPort = server.localPort
                mainThread.post { done(localPort, null) }
                val local = server.accept().apply { tcpNoDelay = true }
                tunnelSockets += local
                pipe(local, remote)
            } catch (error: IOException) {
                Log.w(TAG, "tunnel to $host:$port: $error")
                remote?.let { closeQuietly(it) }
                // Before the port went out, Dart is still waiting on [done].
                if (server == null) mainThread.post { done(null, error.message ?: "connect_failed") }
            } finally {
                server?.let { closeQuietly(it) }
            }
        }
    }

    /** Sends the recorder's UDP keepalive every 2 s over the hotspot. */
    fun startKeepalive(host: String) {
        val joined = network ?: return
        stopKeepalive()
        val payload = "soundcore-keep-alive-unicast".toByteArray()
        val socket: DatagramSocket
        val packet: DatagramPacket
        try {
            socket = DatagramSocket()
            joined.bindSocket(socket)
            // [host] is the recorder's IP literal, so this does no lookup.
            packet = DatagramPacket(payload, payload.size, InetAddress.getByName(host), KEEPALIVE_PORT)
        } catch (error: IOException) {
            Log.w(TAG, "keepalive unavailable: $error")
            return
        }
        keepaliveSocket = socket
        keepalive = Executors.newSingleThreadScheduledExecutor().apply {
            scheduleWithFixedDelay({
                try {
                    socket.send(packet)
                } catch (error: IOException) {
                    Log.w(TAG, "keepalive: $error")
                }
            }, 0, 2, TimeUnit.SECONDS)
        }
    }

    /** Leaves the hotspot and closes everything opened on it. */
    fun release() {
        // Withdrawing the request closes the system dialog without a reply.
        answerJoin?.invoke("cancelled")
        answerJoin = null
        stopKeepalive()
        tunnelSockets.forEach { closeQuietly(it) }
        tunnelSockets.clear()
        callback?.let {
            try {
                connectivity.unregisterNetworkCallback(it)
            } catch (_: IllegalArgumentException) {
                // Already released by the request timing out.
            }
        }
        callback = null
        network = null
    }

    private fun stopKeepalive() {
        keepalive?.shutdownNow()
        keepalive = null
        keepaliveSocket?.close()
        keepaliveSocket = null
    }

    /**
     * Copies bytes both ways. A side that ends half-closes the other, so the
     * recorder's last frames still reach Dart; an error closes both.
     */
    private fun pipe(local: Socket, remote: Socket) {
        val open = AtomicInteger(2)
        fun copy(from: Socket, to: Socket) = io.execute {
            val buffer = ByteArray(16 * 1024)
            try {
                val input = from.getInputStream()
                val output = to.getOutputStream()
                while (true) {
                    val read = input.read(buffer)
                    if (read < 0) break
                    output.write(buffer, 0, read)
                }
                to.shutdownOutput()
                if (open.decrementAndGet() > 0) return@execute
            } catch (_: IOException) {
            }
            closeQuietly(local)
            closeQuietly(remote)
            tunnelSockets -= local
            tunnelSockets -= remote
        }
        copy(local, remote)
        copy(remote, local)
    }

    private fun closeQuietly(closeable: Closeable) {
        try {
            closeable.close()
        } catch (_: IOException) {
        }
    }

    companion object {
        private const val TAG = "KoeSoftAp"
        private const val KEEPALIVE_PORT = 32003
        private const val CONNECT_TIMEOUT_MS = 10_000
        private const val ACCEPT_TIMEOUT_MS = 10_000

        @Volatile private var instance: SoftApNetwork? = null

        fun shared(context: Context): SoftApNetwork =
            instance ?: synchronized(this) {
                instance ?: SoftApNetwork(context.applicationContext).also { instance = it }
            }
    }
}
