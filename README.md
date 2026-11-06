# Kairos Nova

Player IPTV per **Android, iOS e Android TV** con interfaccia futuristica stile piattaforme streaming premium, progettato intorno a due obiettivi: **velocità** e **stabilità**, anche con liste M3U da **300.000+ canali**.

[![Build APK](../../actions/workflows/build.yml/badge.svg)](../../actions/workflows/build.yml)

📦 **APK pronto:** scheda [Releases → latest](../../releases/tag/latest) (si rigenera a ogni push su `main`).

---

## Perché è veloce con 299k canali

| Problema classico | Soluzione in Kairos Nova |
|---|---|
| Parser carica tutto il file in RAM → freeze / crash | **Parser streaming in isolate**: legge a chunk, memoria costante, UI sempre a 60 fps |
| Lista canali in `List<Channel>` → scroll a scatti, filtri lenti | **SQLite + FTS5**: la UI chiede solo le ~40 righe visibili (`LIMIT/OFFSET` su indice), cache LRU di 10 pagine |
| Ricerca = `contains()` su 300k stringhe | **Full-text search FTS5** con prefix matching e `bm25` → "sky sp" trova "Sky Sport F1" in pochi ms |
| Loghi → OOM | Cache su disco + limiti `imageCache` + `memCacheWidth` |
| EPG XMLTV da 500 MB | Parser XMLTV streaming (anche `.gz`), finestra di 7 giorni, indice `(tvg_id, start, stop)` |

## Perché è stabile

Il `StreamEngine` (libmpv via `media_kit`) è progettato "antifragile":

- **Riconnessione automatica** con backoff esponenziale (0.5s → 8s)
- **Failover**: dopo 2 tentativi falliti passa a un **link alternativo** dello stesso canale (stesso `tvg-id` o nome), ordinato per **affidabilità storica** (ogni URL accumula ok/fail)
- **Watchdog**: se il tempo di riproduzione non avanza per 12s, riavvia; se un live "termina", riconnette
- **Un solo player riutilizzato** → zapping senza cold start (~300-600 ms)
- **Profili buffer**: Veloce (4s) / Bilanciato (12s) / Stabile (30s)
- Decodifica hardware `auto-safe`, `reconnect_streamed`, `network-timeout`
- Header HTTP per canale (`#EXTVLCOPT`, `#KODIPROP`) rispettati

## Funzioni

**Sorgenti**
- URL M3U/M3U8, file locale, **Xtream Codes** (login → M3U + EPG automatici, info account/scadenza)
- Più liste, cambio lista attiva, aggiornamento manuale, apertura file `.m3u` dal sistema

**Navigazione**
- Home con hero "Riprendi", Continua a guardare, Preferiti, gruppi, anteprime
- Live / Film / Serie / Radio classificati automaticamente
- Vista lista o griglia, gruppi nascondibili, preferiti persistenti ai refresh
- **Ricerca istantanea** su canali *e* programmi EPG
- **Guida TV a griglia** stile Sky/NOW con linea "adesso", dettagli programma, catch-up

**Player**
- Overlay vetro con now/next e barra avanzamento programma
- **Zapping** con swipe, tasti CH+/CH−, frecce, **numeri canale** da telecomando
- Lista canali laterale sul video, mini-info, badge HD/FHD/4K/LIVE
- Gesture: luminosità (sinistra), volume (destra), doppio tap pausa
- Tracce audio/sottotitoli, velocità (VOD), formato schermo, resume VOD
- **Cambia sorgente** manuale, overlay **diagnostica** (risoluzione, fps, bitrate, buffer, drop, reconnect)
- **Multiview**: fino a 4 stream contemporanei, audio selezionabile

**Download offline**
- Film e episodi scaricabili (menu lungo-tap o dal player), coda con 2 download paralleli
- **Pausa/riprendi** con `Range` HTTP, ripresa automatica dopo crash o riavvio
- Velocità, ETA, spazio usato; il player usa automaticamente il file locale se presente

**TV**
- Rail laterale su schermi larghi, focus D-pad ovunque, `LEANBACK_LAUNCHER`, banner TV
- APK split per ABI (arm64 / arm32 / x86_64)

## Struttura

```
lib/
  core/
    db/kairos_db.dart          # SQLite + FTS5, bulk insert, EPG, stats affidabilità
    m3u/m3u_parser.dart        # parser M3U streaming
    m3u/import_service.dart    # isolate import + progress
    epg/xmltv_parser.dart      # parser XMLTV streaming
    xtream/xtream_api.dart     # player_api.php
    player/stream_engine.dart  # riconnessione, failover, watchdog, health
    download/download_manager.dart # coda download VOD, resume Range, stato in DB
    providers.dart             # Riverpod: settings, paging, ricerca, azioni
    theme/kairos_theme.dart    # palette, GlassPanel, PlasmaText
  features/
    home/ channels/ search/ guide/ player/ multiview/ downloads/ settings/ import/
  shared/widgets/              # ChannelTile, ChannelCard, logo, menu, focus
android/                       # manifest TV, icone, network config (Gradle generato da flutter create)
ios/Runner/Info.plist          # HTTP consentito, audio background, .m3u
.github/workflows/build.yml    # APK automatico → Releases "latest"
```

## Build in locale

```bash
flutter pub get
flutter run                     # dispositivo/emulatore collegato
flutter build apk --release --split-per-abi
flutter build ios --release     # su macOS con Xcode
```

Prima build in locale: esegui `flutter create --org com.kairos --project-name kairos_nova --platforms android,ios .` per generare i file Gradle/Xcode (non sovrascrive manifest, risorse e Info.plist già presenti), come fa la CI.

### Firma release Android
L'APK della CI è firmato con la chiave debug (installabile via sideload). Per il Play Store aggiungi un keystore e la `signingConfigs.release` in `android/app/build.gradle.kts` dopo averlo generato.

## Roadmap suggerita
- PiP nativo Android/iOS (il manifest è già pronto)
- Registrazione live e timer
- Sincronizzazione preferiti via Kairos Control
- Chromecast / AirPlay

---
Kairos Nova non fornisce contenuti: riproduce esclusivamente le liste fornite dall'utente.
