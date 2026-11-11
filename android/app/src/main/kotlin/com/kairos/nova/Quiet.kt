package com.kairos.nova

import android.app.Activity
import android.app.Application
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.content.pm.PackageInstaller
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import java.io.File
import java.io.FileInputStream
import kotlin.concurrent.thread

/**
 * Aggiornamento senza conferma (11 novembre 2026, scelta del titolare): con Android 12 e successivi l'APK già scaricato e
 * verificato in background (kairos-nova-<versione>.apk, vedi Updater.prefetch) si installa da solo con PackageInstaller
 * quando il cliente esce dall'app (nessuna schermata dell'app visibile da [WAIT_MS]), senza nessuna conferma. Android lo
 * permette solo se l'app aggiorna se stessa, ha il permesso «Installa app sconosciute», dichiara
 * UPDATE_PACKAGES_WITHOUT_USER_ACTION e l'APK è costruito per un Android abbastanza recente (targetSdk 35: fino ad Android 17).
 * Un tentativo per versione: se Android chiede comunque la conferma o non riesce, al ritorno resta la proposta («Installa ora»).
 * Flutter riceve [ok] in updateStatus («quiet»): se è vero non propone nulla (AppUpdater).
 * Su Android 11 e precedenti (tutte le Fire TV) non cambia nulla.
 */
object Quiet {
    private const val WAIT_MS = 10_000L
    private val main = Handler(Looper.getMainLooper())
    /** schermate dell'app visibili adesso (tutte le activity) */
    @Volatile var started = 0
        private set
    private var hooked = false
    private var job: Runnable? = null

    private fun prefs(ctx: Context): SharedPreferences = ctx.getSharedPreferences("kx_quiet", Context.MODE_PRIVATE)

    /** versione installata adesso (le app Flutter non hanno BuildConfig) */
    @Suppress("DEPRECATION")
    private fun myCode(ctx: Context): Int = try {
        val p = ctx.packageManager.getPackageInfo(ctx.packageName, 0)
        if (Build.VERSION.SDK_INT >= 28) p.longVersionCode.toInt() else p.versionCode
    } catch (_: Throwable) { Int.MAX_VALUE }

    /** su questo dispositivo si può provare adesso */
    fun possible(ctx: Context): Boolean = Build.VERSION.SDK_INT >= 31 && try { ctx.packageManager.canRequestPackageInstalls() } catch (_: Throwable) { false }

    /** l'interfaccia può lasciare la versione [code] all'installazione senza conferma (niente proposta) */
    fun ok(ctx: Context, code: Int): Boolean = code > myCode(ctx) && possible(ctx) && prefs(ctx).getInt("tried", 0) != code

    /** l'installazione senza conferma della versione [code] è stata bloccata su un Samsung (di solito il «Blocco automatico») */
    fun blocked(ctx: Context, code: Int): Boolean {
        val p = prefs(ctx)
        return code != 0 && p.getInt("failCode", 0) == code && p.getInt("failSt", 0) == 2 && (Build.MANUFACTURER ?: "").equals("samsung", ignoreCase = true)
    }

    /** conta le schermate visibili dell'app: quando arrivano a zero il cliente è uscito (una volta sola per processo) */
    fun watch(app: Application) {
        if (hooked) return
        hooked = true
        app.registerActivityLifecycleCallbacks(object : Application.ActivityLifecycleCallbacks {
            override fun onActivityStarted(a: Activity) { started++; cancel() }
            override fun onActivityStopped(a: Activity) {
                started = maxOf(0, started - 1)
                if (started == 0) schedule(a.applicationContext)
            }
            override fun onActivityCreated(a: Activity, b: Bundle?) {}
            override fun onActivityResumed(a: Activity) {}
            override fun onActivityPaused(a: Activity) {}
            override fun onActivitySaveInstanceState(a: Activity, b: Bundle) {}
            override fun onActivityDestroyed(a: Activity) {}
        })
    }

    private fun schedule(ctx: Context) {
        cancel()
        if (!possible(ctx)) return
        val r = Runnable { job = null; if (started == 0) thread(name = "kx-quiet") { try { tryNow(ctx) } catch (_: Throwable) {} } }
        job = r
        main.postDelayed(r, WAIT_MS)
    }

    private fun cancel() {
        job?.let { main.removeCallbacks(it) }
        job = null
    }

    /** l'APK più nuovo già scaricato (stessa cartella di Updater: Android 12+ è sempre cacheDir/apk), con la sua versione */
    private fun ready(ctx: Context): Pair<File, Int>? = try {
        val mine = myCode(ctx)
        (File(ctx.cacheDir, "apk").listFiles() ?: emptyArray())
            .mapNotNull { f -> Regex("^kairos-nova-(\\d+)\\.apk$").find(f.name)?.groupValues?.get(1)?.toIntOrNull()?.let { f to it } }
            .filter { it.second > mine }
            .maxByOrNull { it.second }
    } catch (_: Throwable) { null }

    @Suppress("DEPRECATION")
    private fun codeOf(ctx: Context, f: File): Int = try {
        val p = ctx.packageManager.getPackageArchiveInfo(f.absolutePath, 0)
        if (p == null) 0 else if (Build.VERSION.SDK_INT >= 28) p.longVersionCode.toInt() else p.versionCode
    } catch (_: Throwable) { 0 }

    /** cliente fuori dall'app da [WAIT_MS]: se c'è una versione pronta e niente lo impedisce, la si installa (thread di lavoro) */
    private fun tryNow(ctx: Context) {
        if (started != 0 || !possible(ctx)) return
        val (f, named) = ready(ctx) ?: return
        if (f.length() < 300_000) return
        val code = codeOf(ctx, f)
        val p = prefs(ctx)
        if (code != named || code <= myCode(ctx) || p.getInt("tried", 0) == code) return
        // il lettore di Nova è dentro l'app: se si sente ancora qualcosa (anche un'altra app) si riprova alla prossima uscita
        if (try { (ctx.getSystemService(Context.AUDIO_SERVICE) as android.media.AudioManager).isMusicActive } catch (_: Throwable) { false }) return
        if (ApkCheck.verify(ctx, f) != null) return // app giusta, più nuova, stessa firma
        if (started != 0) return
        p.edit().putInt("tried", code).apply()
        val ok = install(ctx, f, code) { started == 0 }
        // il cliente è tornato mentre si preparava: nessuna installazione, si riprova alla prossima uscita
        if (!ok && started != 0) p.edit().putInt("tried", 0).apply()
    }

    /** installa [apk] senza conferma; prima di confermare ricontrolla [away] (se il cliente è tornato si annulla tutto) */
    private fun install(ctx: Context, apk: File, code: Int, away: () -> Boolean): Boolean {
        if (Build.VERSION.SDK_INT < 31) return false
        val pi = ctx.packageManager.packageInstaller
        var id = -1
        try {
            val sp = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL)
            sp.setAppPackageName(ctx.packageName)
            sp.setSize(apk.length())
            sp.setRequireUserAction(PackageInstaller.SessionParams.USER_ACTION_NOT_REQUIRED)
            id = pi.createSession(sp)
            pi.openSession(id).use { s ->
                FileInputStream(apk).use { inp ->
                    s.openWrite("base.apk", 0, apk.length()).use { out ->
                        inp.copyTo(out, 64 * 1024)
                        s.fsync(out)
                    }
                }
                if (!away()) { s.abandon(); return false }
                val done = Intent(ctx, QuietDone::class.java).putExtra("code", code)
                val pend = PendingIntent.getBroadcast(ctx, id, done, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE)
                s.commit(pend.intentSender)
            }
            return true
        } catch (t: Throwable) {
            if (id >= 0) try { pi.abandonSession(id) } catch (_: Throwable) {}
            android.util.Log.w("KairosNova", "quiet", t)
            return false
        }
    }

    internal fun failed(ctx: Context, code: Int, st: Int) {
        prefs(ctx).edit().putInt("failCode", code).putInt("failSt", st).apply()
    }
}

/** esito dell'aggiornamento senza conferma (se riesce lo riceve già la versione nuova) */
class QuietDone : BroadcastReceiver() {
    override fun onReceive(ctx: Context, i: Intent) {
        val st = i.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)
        when (st) {
            PackageInstaller.STATUS_SUCCESS -> {}
            PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                // Android vuole comunque la conferma: con il cliente fuori dall'app non si mostra nulla, resta la proposta di sempre
                val sid = i.getIntExtra(PackageInstaller.EXTRA_SESSION_ID, -1)
                if (sid >= 0) try { ctx.packageManager.packageInstaller.abandonSession(sid) } catch (_: Throwable) {}
            }
            else -> try { Quiet.failed(ctx, i.getIntExtra("code", 0), st) } catch (_: Throwable) {}
        }
    }
}
