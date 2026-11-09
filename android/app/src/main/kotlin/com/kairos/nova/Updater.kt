package com.kairos.nova

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.content.pm.Signature
import android.net.ConnectivityManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.widget.Toast
import androidx.core.content.FileProvider
import org.json.JSONObject
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.concurrent.thread

/**
 * Aggiornamento dell'app (parte nativa): la decisione di quando controllare sta in Flutter, qui si scarica,
 * si verifica (stesso pacchetto, versione più nuova, stessa firma) e si apre l'installer di Android.
 * - prefetch: scaricamento in background, senza finestre; a fine corsa Flutter riceve updateEvent {type: ready | failed}
 * - install: se l'APK è già pronto si apre subito l'installer, altrimenti si scarica con gli eventi progress
 * Android chiede comunque la conferma del cliente per installare (nessuna installazione silenziosa senza
 * gestione del dispositivo): l'aggiornamento in background toglie l'attesa del download, non quel tocco.
 */
object Updater {
    private val busy = AtomicBoolean(false)
    private val main = Handler(Looper.getMainLooper())
    @Volatile private var readyFile: File? = null
    @Volatile private var readyCode = 0

    private fun dir(ctx: Context): File = (if (Build.VERSION.SDK_INT >= 24) File(ctx.cacheDir, "apk") else (ctx.externalCacheDir ?: File(ctx.cacheDir, "apk"))).apply { mkdirs() }
    private fun fileFor(ctx: Context, code: Int) = File(dir(ctx), "kairos-nova-$code.apk")

    private fun event(type: String, extra: JSONObject.() -> Unit = {}) {
        val j = JSONObject().put("type", type)
        j.extra()
        main.post { try { MainActivity.channel?.invokeMethod("updateEvent", j.toString()) } catch (_: Exception) {} }
    }

    /** rete a consumo (dati mobili, hotspot): niente download non richiesti */
    fun metered(ctx: Context): Boolean = try {
        (ctx.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager).isActiveNetworkMetered
    } catch (_: Exception) { false }

    /** APK di [code] già scaricato e verificato (anche in un'apertura precedente) */
    fun ready(ctx: Context, code: Int): Boolean {
        if (readyCode == code && readyFile?.exists() == true) return true
        // scaricamento in corso: il file può essere a metà, quindi non è pronto (e non va cancellato)
        if (busy.get()) return false
        val f = fileFor(ctx, code)
        if (!f.exists()) return false
        if (f.length() < 300_000 || ApkCheck.verify(ctx, f) != null) { f.delete(); return false }
        readyFile = f; readyCode = code
        return true
    }

    fun status(ctx: Context, code: Int): Map<String, Any> = mapOf(
        "ready" to ready(ctx, code),
        "metered" to metered(ctx),
        "busy" to busy.get(),
        "canInstall" to (Build.VERSION.SDK_INT < 26 || ctx.packageManager.canRequestPackageInstalls()),
    )

    /**
     * APK adatto al dispositivo. Il feed indica la versione a 64 bit («url»), ma le chiavette Fire TV e i box vecchi hanno
     * Android a 32 bit e non la installano («App non installata», anche con l'aggiornamento obbligatorio che blocca l'app):
     * lì si scarica la versione a 32 bit della stessa release («urlArm32» del feed, [url32]), che il workflow pubblica
     * sempre insieme.
     */
    fun apkFor(url: String, url32: String = ""): String = abiUrl(url, Build.SUPPORTED_64_BIT_ABIS.isNotEmpty(), url32)

    /**
     * APK da provare in ordine per questo dispositivo: quello adatto del feed ([apkFor]), poi le riserve decise da Flutter
     * per la stessa architettura ([alts] a 64 bit, [alts32] a 32 bit: lo stesso APK sulle basi successive, poi GitHub).
     */
    fun chainFor(url: String, url32: String, alts: List<String>, alts32: List<String>): List<String> =
        abiChain(url, Build.SUPPORTED_64_BIT_ABIS.isNotEmpty(), url32, alts, alts32)

    /** logica di [chainFor]: [has64] = il dispositivo esegue app a 64 bit; solo link https, senza doppioni */
    fun abiChain(url: String, has64: Boolean, url32: String, alts: List<String>, alts32: List<String>): List<String> =
        (listOf(abiUrl(url, has64, url32)) + if (has64) alts else alts32).filter { it.startsWith("https://") }.distinct()

    /**
     * logica di [apkFor]: [has64] = il dispositivo esegue app a 64 bit; [url32] = «urlArm32» del feed, vuoto se manca.
     * Senza urlArm32 il link a 32 bit si ricava dal nome: GitHub KairosNova-arm64.apk → KairosNova-arm32.apk,
     * pannello /get/nova.apk → /get/nova-arm32.apk.
     */
    fun abiUrl(url: String, has64: Boolean, url32: String = ""): String = when {
        has64 -> url
        url32.startsWith("https://") -> url32
        url.endsWith("/KairosNova-arm64.apk") -> url.removeSuffix("KairosNova-arm64.apk") + "KairosNova-arm32.apk"
        url.endsWith("/get/nova.apk") -> url.removeSuffix("nova.apk") + "nova-arm32.apk"
        else -> url
    }

    /** scaricamento in background: nessuna finestra; evento ready | failed. [alts]/[alts32]: riserve, vedi [chainFor] */
    fun prefetch(ctx: Context, url: String, code: Int, url32: String = "", alts: List<String> = emptyList(), alts32: List<String> = emptyList()) {
        if (ready(ctx, code)) { event("ready") { put("code", code) }; return }
        if (!busy.compareAndSet(false, true)) return
        thread(name = "kx-apk-bg") {
            try {
                val out = fileFor(ctx, code)
                fetchAny(ctx, chainFor(url, url32, alts, alts32), out, null)
                readyFile = out; readyCode = code
                cleanOld(ctx, out)
                event("ready") { put("code", code) }
            } catch (e: Exception) {
                event("failed") { put("code", code); put("msg", e.message ?: "errore") }
            } finally { busy.set(false) }
        }
    }

    /** installa: subito se l'APK è pronto, altrimenti lo scarica (eventi progress; riserve come in [prefetch]) e poi apre l'installer */
    fun install(a: Activity, url: String, code: Int, url32: String = "", alts: List<String> = emptyList(), alts32: List<String> = emptyList()) {
        if (ready(a, code)) { launch(a, readyFile!!); return }
        if (!busy.compareAndSet(false, true)) { event("busy"); return }
        thread(name = "kx-apk") {
            try {
                val out = fileFor(a, code)
                fetchAny(a, chainFor(url, url32, alts, alts32), out) { p -> event("progress") { put("p", p) } }
                readyFile = out; readyCode = code
                cleanOld(a, out)
                event("progress") { put("p", 100) }
                main.post { launch(a, out) }
            } catch (e: Exception) {
                event("error") { put("msg", e.message ?: "errore") }
            } finally { busy.set(false) }
        }
    }

    private fun cleanOld(ctx: Context, keep: File) {
        try { dir(ctx).listFiles()?.forEach { if (it != keep && it.name.endsWith(".apk")) it.delete() } } catch (_: Exception) {}
    }

    /** il primo di [urls] che si scarica e si verifica ([chainFor]); se nessuno riesce, l'errore del primo */
    private fun fetchAny(ctx: Context, urls: List<String>, out: File, progress: ((Int) -> Unit)?) {
        var err: Exception? = null
        for (u in urls) {
            try {
                fetch(ctx, u, out, progress)
                return
            } catch (e: Exception) {
                if (err == null) err = e
            }
        }
        throw err ?: Exception("download non riuscito")
    }

    /** scarica [url] in [out] seguendo solo redirect https e verifica il file */
    private fun fetch(ctx: Context, url: String, out: File, progress: ((Int) -> Unit)?) {
        var target = URL(url)
        var c = target.openConnection() as HttpURLConnection
        var hops = 0
        while (true) {
            c.instanceFollowRedirects = false
            c.connectTimeout = 20_000
            c.readTimeout = 30_000
            c.setRequestProperty("User-Agent", "KairosNova")
            val code = c.responseCode
            val loc = c.getHeaderField("Location")
            if (code in 300..399 && loc != null && hops < 8) {
                val next = URL(target, loc)
                if (next.protocol != "https") throw Exception("il link dell'APK rimanda a un indirizzo non sicuro")
                c.disconnect(); target = next; hops++
                c = target.openConnection() as HttpURLConnection
                continue
            }
            if (code != 200) throw Exception(if (code == 404) "file non trovato (HTTP 404)" else "HTTP $code")
            break
        }
        try {
            val total = c.contentLength.toLong()
            var done = 0L
            var last = -1
            c.inputStream.use { input ->
                FileOutputStream(out).use { fo ->
                    val buf = ByteArray(64 * 1024)
                    while (true) {
                        val n = input.read(buf)
                        if (n < 0) break
                        fo.write(buf, 0, n)
                        done += n
                        if (total > 0 && progress != null) {
                            val p = ((done * 100) / total).toInt().coerceAtMost(99)
                            if (p != last) { last = p; progress(p) }
                        }
                    }
                }
            }
            if (total > 0 && done != total) { out.delete(); throw Exception("download interrotto: controlla la connessione e riprova") }
        } finally { c.disconnect() }
        val head = ByteArray(2)
        FileInputStream(out).use { it.read(head) }
        if (out.length() < 300_000 || head[0] != 'P'.code.toByte() || head[1] != 'K'.code.toByte()) { out.delete(); throw Exception("il link non porta a un file APK") }
        ApkCheck.verify(ctx, out)?.let { msg -> out.delete(); throw Exception(msg) }
    }

    private fun launch(a: Activity, apk: File) {
        if (Build.VERSION.SDK_INT >= 26 && !a.packageManager.canRequestPackageInstalls()) {
            event("perm")
            Toast.makeText(a, "Consenti a Kairos Nova di installare app, poi torna indietro: l'installazione riparte da sola", Toast.LENGTH_LONG).show()
            val tries = listOf(
                Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:" + a.packageName)),
                Intent(Settings.ACTION_SECURITY_SETTINGS),
                Intent(Settings.ACTION_SETTINGS),
            )
            for (i in tries) { try { a.startActivity(i); return } catch (_: Exception) {} }
            return
        }
        val uri: Uri = if (Build.VERSION.SDK_INT >= 24) FileProvider.getUriForFile(a, a.packageName + ".files", apk) else Uri.fromFile(apk)
        val i = Intent(Intent.ACTION_VIEW)
            .setDataAndType(uri, "application/vnd.android.package-archive")
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
        try { a.startActivity(i); event("installer") } catch (_: Exception) { event("error") { put("msg", "installazione non disponibile su questo dispositivo") } }
    }
}

/** Controlli sull'APK scaricato (stessi delle altre app Kairos): app giusta, versione più nuova, stessa firma */
object ApkCheck {
    fun verify(ctx: Context, apk: File): String? {
        val pm = ctx.packageManager
        val info = archiveInfo(pm, apk.absolutePath, 0) ?: return "Il file scaricato è danneggiato: riprova"
        if (info.packageName != ctx.packageName) return "Il file scaricato non è un aggiornamento di questa app"
        val newCode = code(info)
        val myCode = installedInfo(pm, ctx.packageName)?.let { code(it) } ?: 0L
        if (newCode == myCode) return "È la stessa versione già installata"
        if (newCode < myCode) return "La versione scaricata è più vecchia di quella installata"
        // un APK a 64 bit scaricato prima su un dispositivo a 32 bit non si installa: via, si riscarica quello giusto
        if (!abiOk(apk)) return "Questa versione non è adatta a questo dispositivo: riprova"
        val mine = certs(installedInfo(pm, ctx.packageName))
        val theirs = certs(archiveInfo(pm, apk.absolutePath, sigFlags()))
        if (mine.isNotEmpty() && theirs.isNotEmpty() && mine.intersect(theirs).isEmpty()) return "L'aggiornamento è firmato con una chiave diversa: disinstalla l'app e installala di nuovo dallo store"
        return null
    }

    /** l'APK ha le librerie native per un'architettura che il dispositivo esegue (senza librerie native va bene ovunque) */
    private fun abiOk(apk: File): Boolean = try {
        java.util.zip.ZipFile(apk).use { z ->
            val abis = HashSet<String>()
            val e = z.entries()
            while (e.hasMoreElements()) {
                val n = e.nextElement().name
                if (n.startsWith("lib/")) n.split('/').getOrNull(1)?.takeIf { it.isNotEmpty() }?.let { abis.add(it) }
            }
            abis.isEmpty() || Build.SUPPORTED_ABIS.any { it in abis }
        }
    } catch (_: Exception) { true }

    @Suppress("DEPRECATION")
    private fun code(p: PackageInfo): Long = if (Build.VERSION.SDK_INT >= 28) p.longVersionCode else p.versionCode.toLong()

    @Suppress("DEPRECATION")
    private fun sigFlags(): Int = if (Build.VERSION.SDK_INT >= 28) PackageManager.GET_SIGNING_CERTIFICATES or PackageManager.GET_SIGNATURES else PackageManager.GET_SIGNATURES

    private fun archiveInfo(pm: PackageManager, path: String, flags: Int): PackageInfo? = try { pm.getPackageArchiveInfo(path, flags) } catch (_: Throwable) { null }

    private fun installedInfo(pm: PackageManager, pkg: String): PackageInfo? = try { pm.getPackageInfo(pkg, sigFlags()) } catch (_: Throwable) { null }

    @Suppress("DEPRECATION")
    private fun certs(p: PackageInfo?): Set<String> {
        if (p == null) return emptySet()
        val list = ArrayList<Signature>()
        if (Build.VERSION.SDK_INT >= 28) {
            val si = p.signingInfo
            if (si != null) {
                val arr = if (si.hasMultipleSigners()) si.apkContentsSigners else si.signingCertificateHistory
                if (arr != null) list.addAll(arr)
            }
        }
        if (list.isEmpty()) p.signatures?.let { list.addAll(it) }
        val out = HashSet<String>()
        for (s in list) {
            try {
                val d = MessageDigest.getInstance("SHA-256").digest(s.toByteArray())
                out.add(d.joinToString("") { String.format("%02x", it) })
            } catch (_: Exception) {}
        }
        return out
    }
}
