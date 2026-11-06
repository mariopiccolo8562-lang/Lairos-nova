package com.kairos.nova

import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Parte nativa di Kairos Nova: un solo canale («kairos/nova») per le cose che Flutter non può fare da solo.
 * - deviceInfo: versione e numero di build installati
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
                        android.widget.Toast.makeText(this, "Attiva «Consenti da questa fonte», poi premi INDIETRO", android.widget.Toast.LENGTH_LONG).show()
                        for (i in listOf(android.content.Intent(android.provider.Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, android.net.Uri.parse("package:$packageName")), android.content.Intent(android.provider.Settings.ACTION_SETTINGS))) { try { startActivity(i); break } catch (_: Exception) {} }
                    }
                    result.success(ok)
                }
                "deviceInfo" -> {
                    val pi = try { packageManager.getPackageInfo(packageName, 0) } catch (_: Exception) { null }
                    @Suppress("DEPRECATION")
                    val code = if (pi == null) 0 else (if (Build.VERSION.SDK_INT >= 28) pi.longVersionCode else pi.versionCode.toLong()).toInt()
                    result.success(mapOf(
                        "version" to (pi?.versionName ?: ""),
                        "versionCode" to code,
                        "sdk" to Build.VERSION.SDK_INT,
                        "model" to (Build.MODEL ?: ""),
                        "tv" to packageManager.hasSystemFeature("android.software.leanback"),
                    ))
                }
                "updateStatus" -> result.success(Updater.status(this, (call.argument<Number>("code") ?: 0).toInt()))
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

    override fun onDestroy() {
        if (channel != null) channel = null
        super.onDestroy()
    }
}
