package com.kairos.nova

import android.app.ActivityManager
import android.content.Context
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
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

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val ch = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "kairos/nova")
        channel = ch
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
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
                    if (url.startsWith("https://") && code > 0) Updater.prefetch(this, url, code)
                    result.success(true)
                }
                "updateInstall" -> {
                    val url = call.argument<String>("url") ?: ""
                    val code = (call.argument<Number>("code") ?: 0).toInt()
                    if (url.startsWith("https://") && code > 0) Updater.install(this, url, code)
                    result.success(true)
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
