package com.kairos.nova

import android.content.Context
import android.os.Build
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL

/**
 * «Vado in sfondo» al pannello Kairos quando l'app si chiude (Indietro dalla Home, «Chiudi l'app»): battito con
 * vis:false e state idle, così il pannello la vede subito non in linea. Con la chiusura dell'attività si spegne anche
 * Flutter e il suo battito potrebbe non partire: qui lo manda la parte nativa, in un thread di rete (mai
 * sull'interfaccia). Codice e segreto sono quelli salvati da Flutter (kx_code, kx_secret); senza collegamento non fa nulla.
 */
object PanelBye {
    private const val DEFAULT_SERVER = "https://panel-kairos.com"

    fun send(ctx: Context) {
        try {
            val p = ctx.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
            val code = p.getString("flutter.kx_code", null) ?: return
            val secret = p.getString("flutter.kx_secret", null) ?: return
            if (code.isEmpty() || secret.isEmpty()) return
            val server = (p.getString("flutter.kx_server", null) ?: DEFAULT_SERVER).trimEnd('/')
            if (!server.startsWith("https://")) return
            val version = try {
                ctx.packageManager.getPackageInfo(ctx.packageName, 0).versionName ?: ""
            } catch (_: Exception) { "" }
            val body = JSONObject()
                .put("code", code)
                .put("secret", secret)
                .put("vis", false)
                .put("state", "idle")
                .put("title", "")
                .put("ver", "nova ${version.ifEmpty { "0" }}".take(20))
                .put("model", Build.MODEL ?: "")
                .put("screen", "home")
                .toString()
            Thread {
                var conn: HttpURLConnection? = null
                try {
                    val c = URL("$server/api/player/heartbeat").openConnection() as HttpURLConnection
                    conn = c
                    c.requestMethod = "POST"
                    c.connectTimeout = 5_000
                    c.readTimeout = 5_000
                    c.doOutput = true
                    c.setRequestProperty("Content-Type", "application/json")
                    c.setRequestProperty("User-Agent", "KairosNova/$version")
                    c.outputStream.use { it.write(body.toByteArray(Charsets.UTF_8)) }
                    c.responseCode // la richiesta parte qui; la risposta non serve
                } catch (_: Exception) {
                    // senza rete il pannello la vedrà comunque non in linea dopo qualche minuto
                } finally {
                    conn?.disconnect()
                }
            }.start()
        } catch (_: Exception) {
            // mai un errore alla chiusura dell'app
        }
    }
}
