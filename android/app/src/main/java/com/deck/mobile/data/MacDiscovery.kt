package com.deck.mobile.data

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import android.os.Handler
import android.os.Looper

data class DiscoveredMac(
    val name: String,
    val host: String,
    val port: Int,
)

class MacDiscovery(context: Context) {
    private val appContext = context.applicationContext
    private val nsd = appContext.getSystemService(NsdManager::class.java)
    private val main = Handler(Looper.getMainLooper())
    private val resolving = mutableSetOf<String>()
    private var listener: NsdManager.DiscoveryListener? = null
    private var multicast: WifiManager.MulticastLock? = null

    fun start(onFound: (DiscoveredMac) -> Unit, onLost: (String) -> Unit) {
        stop()
        val wifi = appContext.getSystemService(WifiManager::class.java)
        multicast = wifi?.createMulticastLock("deck-discovery")?.apply {
            setReferenceCounted(false)
            acquire()
        }
        val discovery = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(serviceType: String) = Unit
            override fun onDiscoveryStopped(serviceType: String) = Unit
            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) = Unit
            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) = Unit

            override fun onServiceLost(service: NsdServiceInfo) {
                main.post { onLost(service.serviceName) }
            }

            override fun onServiceFound(service: NsdServiceInfo) {
                val type = service.serviceType.orEmpty()
                if (!type.contains("_deck._tcp")) return
                synchronized(resolving) {
                    if (!resolving.add(service.serviceName)) return
                }
                resolve(service, onFound)
            }
        }
        listener = discovery
        nsd.discoverServices(SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, discovery)
    }

    fun stop() {
        listener?.let { runCatching { nsd.stopServiceDiscovery(it) } }
        listener = null
        synchronized(resolving) { resolving.clear() }
        multicast?.let { if (it.isHeld) runCatching { it.release() } }
        multicast = null
    }

    @Suppress("DEPRECATION")
    private fun resolve(service: NsdServiceInfo, onFound: (DiscoveredMac) -> Unit) {
        nsd.resolveService(
            service,
            object : NsdManager.ResolveListener {
                override fun onResolveFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
                    synchronized(resolving) { resolving.remove(serviceInfo.serviceName) }
                }

                override fun onServiceResolved(serviceInfo: NsdServiceInfo) {
                    val host = serviceInfo.host?.hostAddress?.takeUnless { it.contains(":") }.orEmpty()
                    if (host.isBlank() || serviceInfo.port <= 0) return
                    val mac = DiscoveredMac(serviceInfo.serviceName, host, serviceInfo.port)
                    main.post { onFound(mac) }
                }
            },
        )
    }

    private companion object {
        const val SERVICE_TYPE = "_deck._tcp."
    }
}
