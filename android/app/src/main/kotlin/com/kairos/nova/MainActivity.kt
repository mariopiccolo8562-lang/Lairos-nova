package com.kairos.nova

import android.app.ActivityManager
import android.content.Context
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlin.concurrent.thread

/**
 * Parte nativa di Kairos Nova: un solo canale («kairos/nova») per le cose che Flutter non può fare da solo.
 * - deviceInfo: versione e numero di build installati, modello, memoria del dispositivo
 * - updateStatus / updatePrefetch / updateInstall: aggiornamento dell'app (vedi Updater.kt);
 *   gli esiti arrivano a Flutter con updateEvent
 */
class MainActivity : FlutterActivity() {
    companion object {
        @Volatile var channel: MethodChannel? = null
    }

    /** link di riserva dell'APK decisi da Flutter (stesso APK sulle basi successive, poi GitHub): solo https */
    private fun links(call: MethodCall, key: String): List<String> =
        (call.argument<List<Any?>>(key) ?: emptyList()).mapNotNull { it as? String }.filter { it.startsWith("https://") }

    /** risposta di Android alla richiesta del DNS cifrato (stessa finestra della VPN) */
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: android.content.Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == DnsShield.REQ) DnsShield.onConsent(applicationContext, resultCode == RESULT_OK)
    }
    /** rete del dispositivo per «Online ora» del pannello: tipo (wifi, eth, mobile, none) e segnale Wi-Fi in dBm (13 novembre 2026) */
    private fun netInfo(): Map<String, Any> {
        val out = HashMap<String, Any>()
        var type = "none"
        try {
            val cm = getSystemService(android.content.Context.CONNECTIVITY_SERVICE) as android.net.ConnectivityManager
            if (android.os.Build.VERSION.SDK_INT >= 23) {
                val c = cm.activeNetwork?.let { cm.getNetworkCapabilities(it) }
                if (c != null) type = when {
                    c.hasTransport(android.net.NetworkCapabilities.TRANSPORT_ETHERNET) -> "eth"
                    c.hasTransport(android.net.NetworkCapabilities.TRANSPORT_WIFI) -> "wifi"
                    c.hasTransport(android.net.NetworkCapabilities.TRANSPORT_CELLULAR) -> "mobile"
                    else -> ""
                }
            } else {
                @Suppress("DEPRECATION") val ni = cm.activeNetworkInfo
                @Suppress("DEPRECATION")
                if (ni != null && ni.isConnected) type = when (ni.type) {
                    android.net.ConnectivityManager.TYPE_ETHERNET -> "eth"
                    android.net.ConnectivityManager.TYPE_WIFI -> "wifi"
                    android.net.ConnectivityManager.TYPE_MOBILE -> "mobile"
                    else -> ""
                }
            }
            if (type == "wifi") {
                val wm = applicationContext.getSystemService(android.content.Context.WIFI_SERVICE) as android.net.wifi.WifiManager
                @Suppress("DEPRECATION") val wi = wm.connectionInfo
                if (wi != null && wi.rssi in -126..-1) out["rssi"] = wi.rssi
            }
        } catch (_: Throwable) { }
        out["type"] = type
        return out
    }


    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        Quiet.watch(application) // Android 12+: aggiornamento senza conferma quando il cliente esce dall'app
        super.configureFlutterEngine(flutterEngine)
        val ch = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "kairos/nova")
        channel = ch
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "netInfo" -> result.success(netInfo())
                "openInstallPerm" -> {
                    val ok = android.os.Build.VERSION.SDK_INT < 26 || packageManager.canRequestPackageInstalls()
                    if (!ok) {
                        android.widget.Toast.makeText(this, "Attiva «Consenti da questa fonte» per gli aggiornamenti dell'app, poi premi INDIETRO", android.widget.Toast.LENGTH_LONG).show()
                        for (i in listOf(android.content.Intent(android.provider.Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, android.net.Uri.parse("package:$packageName")), android.content.Intent(android.provider.Settings.ACTION_SETTINGS))) { try { startActivity(i); break } catch (_: Exception) {} }
                    }
                    result.success(ok)
                }
                "deviceInfo" -> {
                    val pi = try { packageManager.getPackageInfo(packageName, 0) } catch (_: Exception) { null }
                    @Suppress("DEPRECATION")
                    val code = if (pi == null) 0 else (if (Build.VERSION.SDK_INT >= 28) pi.longVersionCode else pi.versionCode.toLong()).toInt()
                    // memoria del dispositivo: classe D (≤ 1,2 GB) per la grafica e le cache delle immagini
                    val am = getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager
                    val mi = ActivityManager.MemoryInfo()
                    try { am?.getMemoryInfo(mi) } catch (_: Exception) {}
                    result.success(mapOf(
                        "version" to (pi?.versionName ?: ""),
                        "versionCode" to code,
                        "sdk" to Build.VERSION.SDK_INT,
                        "model" to (Build.MODEL ?: ""),
                        "tv" to packageManager.hasSystemFeature("android.software.leanback"),
                        "lowRam" to (am?.isLowRamDevice ?: false),
                        "totalMemMb" to (mi.totalMem / (1024L * 1024L)).toInt(),
                    ))
                }
                "updateStatus" -> {
                    val code = (call.argument<Number>("code") ?: 0).toInt()
                    // verificare l'APK già scaricato (pacchetto, versione, firma) vuol dire leggere tutto il file:
                    // fuori dal thread dell'interfaccia, anche all'avvio quando si controlla l'aggiornamento obbligatorio
                    thread(name = "kx-apk-status") {
                        val st: Map<String, Any> = try { Updater.status(this, code) } catch (_: Exception) { mapOf("ready" to false) }
                        runOnUiThread { result.success(st) }
                    }
                }
                "updatePrefetch" -> {
                    val url = call.argument<String>("url") ?: ""
                    val code = (call.argument<Number>("code") ?: 0).toInt()
                    val url32 = call.argument<String>("url32") ?: "" // «urlArm32» del feed: APK per Android a 32 bit
                    if (url.startsWith("https://") && code > 0) Updater.prefetch(this, url, code, url32, links(call, "alts"), links(call, "alts32"))
                    result.success(true)
                }
                "updateInstall" -> {
                    val url = call.argument<String>("url") ?: ""
                    val code = (call.argument<Number>("code") ?: 0).toInt()
                    val url32 = call.argument<String>("url32") ?: ""
                    if (url.startsWith("https://") && code > 0) Updater.install(this, url, code, url32, links(call, "alts"), links(call, "alts32"))
                    result.success(true)
                }
                // DNS cifrato (voce «sdns» del pannello): lo decide la parte Flutter, qui si accende e si spegne (DnsShield.kt)
                "dnsStart" -> { DnsShield.start(this); result.success(DnsShield.state) }
                "dnsStop" -> { DnsShield.stop(applicationContext); result.success(DnsShield.state) }
                "dnsState" -> result.success(DnsShield.state)
                // trailer dentro l'app (TrailerActivity, in un processo a parte): video di YouTube oppure file diretto
                "trailer" -> {
                    val title = call.argument<String>("title") ?: ""
                    val id = Yt.id(call.argument<String>("yt") ?: "")
                    val file = call.argument<String>("url") ?: ""
                    when {
                        id != null -> { TrailerActivity.start(this, id, title); result.success(true) }
                        TrailerActivity.fileOk(file) -> { TrailerActivity.startFile(this, file, title); result.success(true) }
                        else -> result.success(false)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onPause() {
        // l'app si chiude (Indietro dalla Home, «Chiudi l'app»): il pannello la vede subito non in linea
        if (isFinishing) PanelBye.send(applicationContext)
        super.onPause()
    }

    override fun onDestroy() {
        if (channel != null) channel = null
        super.onDestroy()
    }
}
