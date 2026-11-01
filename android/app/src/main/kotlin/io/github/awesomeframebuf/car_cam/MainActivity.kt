package io.github.awesomeframebuf.car_cam

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.Bundle
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity() {
    private val connectivity by lazy {
        getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
    }

    // The car's Wi-Fi has no internet, so Android would otherwise keep sending
    // traffic over mobile data and the car would never hear from the app.
    private val wifiCallback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) {
            connectivity.bindProcessToNetwork(network)
        }

        override fun onLost(network: Network) {
            connectivity.bindProcessToNetwork(null)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        val request = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            .removeCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .build()
        connectivity.requestNetwork(request, wifiCallback)
    }

    override fun onDestroy() {
        connectivity.unregisterNetworkCallback(wifiCallback)
        connectivity.bindProcessToNetwork(null)
        super.onDestroy()
    }
}
