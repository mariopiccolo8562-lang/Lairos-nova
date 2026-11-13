import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show AppLifecycleListener, AppLifecycleState, WidgetsBinding;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../dns_badge.dart';
import '../images.dart';
import '../m3u/m3u_parser.dart' show hideSepNames;
import '../models/models.dart';
import '../player/stream_engine.dart';
import '../providers.dart';
import '../xtream/xtream_api.dart';
import '../trend_match.dart';
import 'panel_client.dart';
import 'remote_quiet.dart';

/// Comando del pannello che tocca l'interfaccia (lo esegue la shell): reload | settings | exit.
class UiCommand {
  const UiCommand(this.kind, this.seq);
  final String kind;
  final int seq;
}

/// Collegamento facoltativo al fornitore (pannello Kairos Control), come le altre app Kairos.
/// - Il cliente comunica il codice KX..-.... al fornitore; appena lo attiva, le sue liste arrivano da sole.
/// - Battito ogni minuto («Online ora», impostazioni imposte, comandi, «Invia aggiornamento»), solo con l'app
///   visibile: ogni battito porta vis:true; quando l'app va in sfondo parte un solo battito vis:false.
/// - Senza collegamento l'app resta libera: liste proprie, aggiornamenti dal feed pubblico.
class PanelService extends ChangeNotifier {
  PanelService(this._ref, this._prefs) {
    final code = _prefs.getString('kx_code') ?? '';
    final secret = _prefs.getString('kx_secret') ?? '';
    if (code.isNotEmpty && secret.isNotEmpty) _identity = PanelIdentity(code, secret);
    _server = _prefs.getString('kx_server') ?? kDefaultPanelUrl;
    _rc = _decode(_prefs.getString('kx_rc'));
    hideSepNames = _rc['o.sep'] != 'off';
    _rcv = _prefs.getString('kx_rcv') ?? '';
    _map = _decode(_prefs.getString('kx_pl_map'));
    _sigs = _decode(_prefs.getString('kx_pl_sig'));
    _perms = PanelState.parsePerms(_prefs.getString('kx_perms'));
    // a lettore chiuso ripartono i lavori rimandati durante la visione (liste, refresh)
    _ref.listen<int>(watchingProvider, (_, n) {
      if (n == 0) unawaited(_runDeferred());
      // PIN reimpostato durante la visione: a lettore chiuso si chiede subito il nuovo PIN
      if (n == 0 && _pinAsk.pending) {
        Timer(const Duration(milliseconds: 1200), () {
          if (!_disposed && !_watching && _pinAsk.onViewEnd()) _emit('pin');
        });
      }
    });
    // presenza: «in sfondo» quando nessuna schermata dell'app è visibile (hidden / paused / detached)
    final now = WidgetsBinding.instance.lifecycleState;
    _visible = now == null || now == AppLifecycleState.resumed || now == AppLifecycleState.inactive;
    _life = AppLifecycleListener(
      onShow: () => _setVisible(true),
      onResume: () => _setVisible(true),
      onHide: () => _setVisible(false),
      onPause: () => _setVisible(false),
      onDetach: () => _setVisible(false),
    );
  }

  final Ref _ref;
  final SharedPreferences _prefs;
  PanelIdentity? _identity;
  String _server = kDefaultPanelUrl;
  PanelClient? _client;
  PanelState? state;
  String? lastError;
  bool busy = false;
  Timer? _poll;
  Timer? _beat;
  Timer? _refresh;
  int _kickSeen = 0;
  int _updSeen = 0;
  /// PIN reimpostato dal pannello durante la visione: il nuovo PIN si chiede a visione finita.
  final PinAsk _pinAsk = PinAsk();
  // presenza (vis): app visibile, battito in viaggio, «vado in sfondo» in viaggio, nuovo tentativo al ritorno
  AppLifecycleListener? _life;
  bool _visible = true;
  bool _beating = false;
  bool _disposed = false;
  Future<void>? _beatCall;
  Future<void>? _byeCall;
  int _byeSeq = 0;
  Timer? _resumeTimer;
  final Stopwatch _clock = Stopwatch()..start();
  int _lastOk = -1; // ultimo battito accettato dal pannello (ms di _clock): vale per il limite dei 15 s
  /// Permessi del cliente dal pannello (chiave assente = consentito), salvati in `kx_perms`.
  Map<String, bool> _perms = const {};
  /// Lavori rimandati perché c'era un lettore aperto (§7: niente download di liste durante la visione).
  List<PanelPlaylist>? _pendingPlaylists;
  bool _pendingRefresh = false;
  bool _pendingResync = false;
  /// Classe dispositivo (D debole / N normale / O ottimo) riportata al pannello.
  String _dev = 'N';
  bool get _watching => _ref.read(watchingProvider) > 0;
  Map<String, String> _rc = const {};
  String _rcv = '';
  /// La voce è imposta dal fornitore nel pannello: nell'app si vede ma non si cambia.
  bool imposed(String key) => (_rc[key] ?? '').isNotEmpty;

  /// Funzione consentita dal fornitore (permessi del cliente; senza collegamento o chiave assente = sì).
  bool perm(String key) => !linked || _perms[key] != false;
  Map<String, String> _map = const {}; // id lista del pannello → id lista in Nova
  Map<String, String> _sigs = const {}; // id lista del pannello → impronta importata
  int _seq = 0;
  String _version = '';
  String _model = '';

  /// Comandi per la shell (riavvia interfaccia, apri impostazioni, chiudi).
  final ValueNotifier<UiCommand?> uiCommand = ValueNotifier(null);

  bool get linked => _identity != null;
  bool get active => state?.active == true;
  String get code => _identity?.code ?? '';
  Map<String, String> get remoteConfig => _rc;

  /// Classifica di tendenza (13 novembre 2026): si riscarica al più ogni 6 ore; senza risposta resta l'ultima.
  TrendList _trend = TrendList.empty;
  int _trendAt = 0;
  Future<TrendList>? _trendCall;

  Future<TrendList> trending() {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _trendAt < 6 * 3600 * 1000) return Future.value(_trend);
    return _trendCall ??= () async {
      try {
        final c = _client;
        final t = c == null ? null : await c.trending();
        _trendAt = DateTime.now().millisecondsSinceEpoch;
        if (t != null && !t.isEmpty) _trend = t;
        return _trend;
      } finally {
        _trendCall = null;
      }
    }();
  }

  /// Trailer cercato dal pannello e aperto dentro l'app (parte Android: TrailerActivity). [kind]: movie | series.
  /// false se non c'è un trailer o non si può aprire su questo dispositivo.
  Future<bool> openTrailer(String title, String kind) async {
    final c = _client;
    if (c == null || !linked) return false;
    final t = await c.trailer(title, kind);
    if (t == null) return false;
    try {
      final ok = await const MethodChannel('kairos/nova')
          .invokeMethod<Object?>('trailer', {'yt': t.yt, 'url': t.url, 'title': t.title.isEmpty ? title : t.title});
      return ok == true;
    } on Object {
      return false;
    }
  }

  /// Liste che arrivano dal fornitore (id in Nova).
  Set<int> get providerPlaylistIds => {for (final v in _map.values) int.tryParse(v) ?? -1}..remove(-1);

  // ------------------------------------------------------------------ avvio

  /// Chiamato una volta dalla shell con versione, modello e livello Android (dalla parte nativa).
  Future<void> start({required String version, required String model, int sdk = 0}) async {
    _version = version;
    _model = model;
    _dev = deviceClass(model, sdk);
    if (!linked) return;
    _client = _mkClient();
    unawaited(refresh());
    _startBeat();
    _refresh?.cancel();
    _refresh = Timer.periodic(const Duration(hours: 6), (_) {
      // con un lettore aperto il refresh si rinvia alla chiusura
      if (_watching) {
        _pendingRefresh = true;
      } else {
        unawaited(refresh());
      }
    });
  }

  /// Classe dispositivo di Kairos Adaptive: D = Android < 7 o modello low-end noto (Fire TV Stick 1ª/2ª gen,
  /// Stick Lite, Fire TV 1ª gen); O = Android ≥ 9; N = il resto. Senza il livello Android resta N (o D dal modello).
  static String deviceClass(String model, int sdk) {
    const lowEnd = {'AFTM', 'AFTT', 'AFTSS', 'AFTB'};
    if ((sdk > 0 && sdk < 24) || lowEnd.contains(model.trim().toUpperCase())) return 'D';
    if (sdk >= 28) return 'O';
    return 'N';
  }

  PanelClient _mkClient() => PanelClient(
        identity: _identity!,
        server: _server,
        model: _model,
        version: _version,
        onServerChanged: (s) {
          _server = s;
          _prefs.setString('kx_server', s);
        },
      );

  /// L'app torna in primo piano: battito subito (se il ciclo di vita non l'ha già fatto).
  void onForeground() => _setVisible(true);

  /// Battito periodico: ogni minuto, solo se collegata e con l'app visibile.
  void _startBeat() {
    _beat?.cancel();
    _beat = linked && _visible && !_disposed ? Timer.periodic(const Duration(seconds: 60), (_) => unawaited(heartbeat())) : null;
  }

  /// L'app è andata in sfondo o è tornata visibile: lo si dice subito al pannello.
  void _setVisible(bool visible) {
    if (visible == _visible || _disposed) return;
    _visible = visible;
    _resumeTimer?.cancel();
    _resumeTimer = null;
    if (visible) {
      _startBeat();
      unawaited(_resumeBeat());
    } else {
      _beat?.cancel();
      _beat = null;
      final seq = ++_byeSeq;
      _byeCall = _sendBye(_byeCall).whenComplete(() {
        if (seq == _byeSeq) _byeCall = null;
      });
    }
  }

  /// Di nuovo visibile: battito subito (vis:true). Se il pannello chiede di aspettare (15 s dall'ultimo battito
  /// vero, HTTP 429 «wait») si riprova dopo l'attesa; senza rete o con un battito già in viaggio, tra poco.
  Future<void> _resumeBeat([int round = 0]) async {
    _resumeTimer?.cancel();
    _resumeTimer = null;
    if (!_visible || _disposed) return;
    final wait = await heartbeat();
    if (wait == 0 || !_visible || _disposed || round >= 4) return;
    _resumeTimer = Timer(Duration(milliseconds: wait > 0 ? wait + 500 : 3000), () => unawaited(_resumeBeat(round + 1)));
  }

  /// Un solo battito «vado in sfondo» (vis:false, idle) con gli stessi campi di sempre, dopo quelli ancora in viaggio.
  /// Non aggiorna l'istante dell'ultimo battito: al ritorno in primo piano il battito parte subito.
  Future<void> _sendBye(Future<void>? before) async {
    try {
      if (before != null) await before;
      final regular = _beatCall;
      if (regular != null) await regular;
      final c = _client;
      if (_visible || c == null || state == null || !state!.active) return;
      await c.heartbeat(state: 'idle', screen: 'home', kickAck: _kickSeen, cfg: _cfg(), stats: {'dev': _dev}, rcv: _rcv, vis: false);
    } catch (_) {
      // senza rete il pannello la vedrà comunque non in linea dopo qualche minuto
    }
  }

  // ------------------------------------------------------------------ collegamento

  /// Genera il codice (se non c'è) e si presenta al pannello; poi riprova ogni 15 s finché il fornitore attiva.
  Future<void> link() async {
    if (_identity == null) {
      _identity = PanelIdentity.generate();
      await _prefs.setString('kx_code', _identity!.code);
      await _prefs.setString('kx_secret', _identity!.secret);
    }
    _client = _mkClient();
    if (_beat == null) _startBeat();
    notifyListeners();
    await refresh();
    _poll?.cancel();
    if (state?.pending == true || state == null) {
      _poll = Timer.periodic(const Duration(seconds: 15), (_) async {
        await refresh();
        if (state?.pending != true && state != null) _poll?.cancel();
      });
    }
  }

  /// Si ripresenta al pannello: stato, scadenza, liste.
  Future<void> refresh() async {
    final c = _client;
    if (c == null || busy) return;
    busy = true;
    notifyListeners();
    try {
      final s = await c.register();
      state = s;
      lastError = null;
      if (s.active) _applyPerms(s.perms);
      if (s.raw.containsKey('rc')) _applyRc(s.raw['rc'], (s.raw['rcv'] ?? '').toString());
      unawaited(_syncDns()); // a ogni apertura, anche se la configurazione è la stessa di prima
      if (s.active) {
        if (_watching) {
          _pendingPlaylists = s.playlists; // niente download di liste durante la visione: a lettore chiuso
        } else {
          await _syncPlaylists(s.playlists);
        }
      }
    } on PanelException catch (e) {
      lastError = e.message;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  /// Scollega: via codice, segreto e liste del fornitore. L'app torna libera.
  Future<void> unlink() async {
    _poll?.cancel();
    _beat?.cancel();
    _beat = null;
    _refresh?.cancel();
    final db = _ref.read(dbProvider);
    for (final id in providerPlaylistIds) {
      db.deletePlaylist(id);
    }
    _identity = null;
    _client = null;
    state = null;
    _rc = const {};
    hideSepNames = _rc['o.sep'] != 'off';
    _rcv = '';
    _perms = const {};
    _map = const {};
    _sigs = const {};
    for (final k in ['kx_code', 'kx_secret', 'kx_rc', 'kx_rcv', 'kx_pl_map', 'kx_pl_sig', 'kx_perms']) {
      await _prefs.remove(k);
    }
    _ref.read(appUpdaterProvider).applyRemotePolicy(const {});
    _ref.read(dataVersionProvider.notifier).state++;
    final rest = db.playlists();
    if (rest.isNotEmpty) _ref.read(actionsProvider).setActivePlaylist(rest.first.id);
    notifyListeners();
  }

  // ------------------------------------------------------------------ liste del fornitore

  /// Le liste del fornitore diventano liste di Nova: nuove → create e importate; cambiate → reimportate;
  /// tolte → eliminate. Le liste aggiunte dal cliente a mano non si toccano.
  Future<void> _syncPlaylists(List<PanelPlaylist> pls) async {
    final db = _ref.read(dbProvider);
    final map = Map<String, String>.from(_map);
    final sigs = Map<String, String>.from(_sigs);
    final seen = <String>{};
    var changed = false;
    for (final p in pls) {
      if (p.id.isEmpty) continue;
      seen.add(p.id);
      final existingId = int.tryParse(map[p.id] ?? '');
      final existing = existingId == null ? null : db.playlist(existingId);
      if (existing != null && sigs[p.id] == p.signature) continue; // già importata e uguale
      if (existing != null) db.deletePlaylist(existing.id);
      final int id;
      if (p.isXtream) {
        id = db.insertPlaylist(name: p.name, kind: PlaylistKind.xtream, source: p.server, username: p.username, password: p.password, epgUrl: XtreamApi(baseUrl: p.server, username: p.username, password: p.password).xmltvUrl());
      } else {
        final u = p.m3uUrl;
        if (u.isEmpty) continue;
        id = db.insertPlaylist(name: p.name, kind: PlaylistKind.m3uUrl, source: u);
      }
      map[p.id] = '$id';
      changed = true;
      final pl = db.playlist(id);
      if (pl == null) continue;
      try {
        await _ref.read(actionsProvider).importPlaylist(pl, (_) {});
        sigs[p.id] = p.signature;
      } catch (e) {
        lastError = 'Lista «${p.name}»: ${e.toString().replaceFirst('Exception: ', '')}';
      }
    }
    for (final k in map.keys.toList()) {
      if (seen.contains(k)) continue;
      final id = int.tryParse(map[k] ?? '');
      if (id != null) db.deletePlaylist(id);
      map.remove(k);
      sigs.remove(k);
      changed = true;
    }
    _map = map;
    _sigs = sigs;
    await _prefs.setString('kx_pl_map', jsonEncode(map));
    await _prefs.setString('kx_pl_sig', jsonEncode(sigs));
    if (changed) {
      _ref.read(dataVersionProvider.notifier).state++;
      final active = _ref.read(activePlaylistIdProvider);
      final ids = providerPlaylistIds;
      if (ids.isNotEmpty && (active == null || db.playlist(active) == null)) _ref.read(actionsProvider).setActivePlaylist(ids.first);
    }
  }

  /// Riscarica le liste del fornitore (comando «Aggiorna le liste» o tasto in Impostazioni).
  Future<String> resync() async {
    if (_watching) {
      _pendingResync = true;
      return 'rinviato a fine visione';
    }
    final db = _ref.read(dbProvider);
    var n = 0;
    for (final id in providerPlaylistIds) {
      final pl = db.playlist(id);
      if (pl == null) continue;
      try {
        await _ref.read(actionsProvider).importPlaylist(pl, (_) {});
        n++;
      } catch (_) {}
    }
    return n == 0 ? 'nessuna lista del fornitore' : '$n liste aggiornate';
  }

  /// Esegue i lavori rimandati durante la visione (una volta chiuso il lettore).
  Future<void> _runDeferred() async {
    if (_watching || busy) return;
    if (_pendingRefresh) {
      _pendingRefresh = false;
      _pendingPlaylists = null;
      await refresh();
    }
    final pls = _pendingPlaylists;
    if (pls != null && !_watching) {
      _pendingPlaylists = null;
      busy = true;
      notifyListeners();
      try {
        await _syncPlaylists(pls);
      } finally {
        busy = false;
        notifyListeners();
      }
    }
    if (_pendingResync && !_watching) {
      _pendingResync = false;
      await resync();
    }
  }

  // ------------------------------------------------------------------ battito e controllo remoto

  /// Impostazioni attuali dell'app riportate al pannello (controllo remoto).
  Map<String, Object?> _cfg() {
    final sett = _ref.read(settingsProvider);
    return {
      'bgupd': _ref.read(appUpdaterProvider).bgUpdate ? 'on' : 'off',
      'p.buffer': switch (sett.bufferProfile) { BufferProfile.lowLatency => 'fast', BufferProfile.balanced => 'balanced', BufferProfile.stable => 'stable' },
      'tvmode': sett.tvMode ? 'on' : 'off',
    };
  }

  /// Battito (vis:true), solo con l'app visibile. Restituisce 0 se è partito (o non serve), altrimenti i millisecondi
  /// dopo cui riprovare (limite dei 15 s, HTTP 429 «wait») oppure -1 (rete, battito già in viaggio).
  /// Solo un battito accettato conta come ultimo battito: uno fallito o rifiutato si riprova presto.
  Future<int> heartbeat() async {
    final c = _client;
    if (c == null || state == null || !state!.active || !_visible || _disposed) return 0;
    if (_beating) return -1;
    final now = _clock.elapsedMilliseconds;
    // il pannello accetta al massimo un battito ogni 15 s
    if (_lastOk >= 0 && now - _lastOk < 15000) return 15000 - (now - _lastOk);
    _beating = true;
    try {
      // il «vado in sfondo» ancora in viaggio deve arrivare prima di questo battito
      final bye = _byeCall;
      if (bye != null) {
        await bye;
        if (!_visible) return 0;
      }
      final watching = _watching;
      // il motore si legge solo se esiste già: il battito non deve crearne uno (libmpv) a vuoto
      final engine = StreamEngine.active;
      final st = engine?.status.value;
      final playing = st != null && (st.state == EngineState.playing || st.state == EngineState.buffering);
      final title = watching && playing ? (st?.channel?.name ?? '') : '';
      // misure del lettore per «Online ora»: bw (Mbps), line, dev, stalls10, ttff, fmt, drop
      final stats = <String, Object?>{
        if (engine != null) ...engine.panelStats() else 'line': StreamEngine.savedLine(_prefs),
        'dev': _dev,
      };
      await _readDns();
      final net = await _netInfo();
      final call = c.heartbeat(net: net, sdns: _dnsWanted ? _dns : '', state: watching ? 'playing' : 'idle', title: title, screen: watching ? 'player' : 'home', kickAck: _kickSeen, cfg: _cfg(), stats: stats, rcv: _rcv, vis: true);
      _beatCall = call;
      final r = await call.whenComplete(() {
        if (identical(_beatCall, call)) _beatCall = null;
      });
      if (!watching) unawaited(_runDeferred());
      if (r.status == 429) {
        final w = r.body?['wait'];
        return w is num && w > 0 ? (w * 1000).round() : -1;
      }
      final j = r.status == 200 ? r.body : null;
      if (j == null) return -1;
      // il limite dei 15 s si conta dalla risposta: dalla partenza, un battito arrivato più in fretta del precedente cadeva
      // prima dei 15 s e il pannello lo rifiutava (429)
      _lastOk = _clock.elapsedMilliseconds;
      if (j['rc'] != null) _applyRc(j['rc'], (j['rcv'] ?? '').toString());
      // permessi spenti dal pannello (es. «risoluzione e FPS»): valgono subito, senza aspettare la riapertura
      if (j.containsKey('ph')) _applyPerms(PanelState.parsePerms(j['ph']));
      // «Disconnetti» dal pannello: come nelle altre app Kairos si interrompe la visione in corso, senza avvisi; l'abbonamento
      // resta attivo e l'app collegata (prima Nova si scollegava: via codice e liste, e il cliente andava riattivato con un
      // codice nuovo). La conferma (kickAck) parte col battito successivo: uno subito il pannello lo rifiuterebbe (15 s)
      final kick = (j['kick'] is num) ? (j['kick'] as num).toInt() : 0;
      if (kick > 0 && kick != _kickSeen) {
        _kickSeen = kick;
        if (_watching) _emit('kick');
      }
      // «Invia aggiornamento»
      final upd = (j['upd'] is num) ? (j['upd'] as num).toInt() : 0;
      if (upd > 0 && upd != _updSeen) {
        _updSeen = upd;
        unawaited(_ref.read(appUpdaterProvider).fromPanel());
      }
      // le liste sono cambiate nel pannello: ci si ripresenta
      final pv = (j['pv'] ?? '').toString();
      if (pv.isNotEmpty && pv != (_prefs.getString('kx_pv') ?? '')) {
        await _prefs.setString('kx_pv', pv);
        unawaited(refresh());
      }
      final cmds = j['cmds'];
      if (cmds is List) await _run(cmds, c);
      return 0;
    } finally {
      _beating = false;
    }
  }

  /// Permessi del cliente dal pannello (apertura o battito): si salvano e valgono subito.
  void _applyPerms(Map<String, bool> next) {
    if (_offKeys(next) == _offKeys(_perms)) return;
    _perms = next;
    _prefs.setString('kx_perms', jsonEncode(next));
    notifyListeners();
  }

  static String _offKeys(Map<String, bool> m) => ([for (final e in m.entries) if (!e.value) e.key]..sort()).join(',');

  /// DNS cifrato deciso dal pannello (voce «sdns»: on | off, vuota = spento): acceso solo con il dispositivo attivo.
  /// Non è una scelta del cliente. [_dns] = stato dell'ultima volta, per il battito.
  String _dns = '';
  bool get _dnsWanted => _rc['sdns'] == 'on';
  /// rete del dispositivo (tipo e segnale Wi-Fi) per «Online ora» del pannello
  Future<Map<String, Object?>> _netInfo() async {
    try {
      final r = await const MethodChannel('kairos/nova').invokeMethod<Object?>('netInfo');
      return r is Map ? r.map((k, v) => MapEntry(k.toString(), v)) : const {};
    } catch (_) {
      return const {};
    }
  }

  /// Stato per il lucchetto accanto alla «K» (vuoto = niente lucchetto): vedi [DnsBadge].
  final ValueNotifier<String> dnsBadge = ValueNotifier('');

  Future<void> _syncDns() async {
    final on = _dnsWanted && active;
    try {
      _dns = (await const MethodChannel('kairos/nova').invokeMethod<Object?>(on ? 'dnsStart' : 'dnsStop'))?.toString() ?? '';
    } catch (_) {
      _dns = '';
    }
    if (_disposed) return;
    dnsBadge.value = DnsBadge.state(on, _dns);
    if (!on) return;
    // l'avvio (e la richiesta di Android, la prima volta) dura qualche secondo: il lucchetto si aggiorna da solo
    for (final ms in const [1500, 4000, 9000]) {
      unawaited(Future<void>.delayed(Duration(milliseconds: ms), _readDns));
    }
  }

  Future<void> _readDns() async {
    if (_disposed || !_dnsWanted) return;
    try {
      _dns = (await const MethodChannel('kairos/nova').invokeMethod<Object?>('dnsState'))?.toString() ?? '';
    } catch (_) {}
    if (_disposed) return;
    dnsBadge.value = DnsBadge.state(active, _dns);
  }

  void _applyRc(Object? raw, String rcv) {
    Map<String, String> next = const {};
    try {
      final d = raw is String ? (raw.isEmpty ? const {} : jsonDecode(raw)) : raw;
      if (d is Map) next = {for (final e in d.entries) if (e.value != null) e.key.toString(): e.value.toString()};
    } catch (_) {}
    if (jsonEncode(next) == jsonEncode(_rc) && rcv == _rcv) return;
    _rc = next;
    hideSepNames = _rc['o.sep'] != 'off';
    _rcv = rcv;
    unawaited(_syncDns()); // voce «sdns» accesa o spenta dal pannello
    _prefs.setString('kx_rc', jsonEncode(next));
    _prefs.setString('kx_rcv', rcv);
    _ref.read(appUpdaterProvider).applyRemotePolicy({for (final k in ['bgupd', 'force']) if (next.containsKey(k)) k: next[k]!});
    // buffer e modalità TV imposti dal fornitore: le Impostazioni li riapplicano sopra le scelte del cliente
    Future.microtask(() { try { _ref.read(settingsProvider.notifier).remoteChanged(); } catch (_) {} });
    notifyListeners();
  }

  Future<void> _run(List cmds, PanelClient c) async {
    for (final raw in cmds) {
      if (raw is! Map) continue;
      final id = (raw['id'] is num) ? (raw['id'] as num).toInt() : 0;
      final cmd = (raw['c'] ?? '').toString();
      final args = raw['a'] is Map ? raw['a'] as Map : const {};
      try {
        switch (cmd) {
          case 'reload':
            await c.cmdAck(id, true, 'interfaccia riavviata');
            _emit('reload');
          case 'cache':
            PaintingBinding.instance.imageCache.clear();
            PaintingBinding.instance.imageCache.clearLiveImages();
            try {
              await NovaImageCache.instance.emptyCache(); // la cache su disco delle immagini (la stessa di prima)
            } catch (_) {}
            final info = await resync();
            await c.cmdAck(id, true, 'cache svuotata, $info');
            _emit('reload');
          case 'sync':
            await c.cmdAck(id, true, await resync());
          case 'settings':
            await c.cmdAck(id, true, 'impostazioni aperte');
            _emit('settings${args['sec'] != null ? ':${args['sec']}' : ''}');
          case 'update':
            await c.cmdAck(id, true, await _ref.read(appUpdaterProvider).fromPanel());
          case 'perm':
            // «Chiedi il permesso»: apre la schermata di Android «Installa app sconosciute» (nessuna app può attivarlo da sola)
            final had = await const MethodChannel('kairos/nova').invokeMethod<bool>('openInstallPerm') ?? false;
            await c.cmdAck(id, true, had ? 'permesso già concesso' : 'schermata del permesso aperta sulla TV');
          case 'pin':
            _ref.read(settingsProvider.notifier).update((x) => x.copyWith(clearPin: true, pinLater: 0));
            _ref.read(parentalUnlockedProvider.notifier).state = false;
            await c.cmdAck(id, true, 'PIN riportato a 0000');
            // senza avvisi sul «fornitore»: si chiede subito il nuovo PIN, come alla prima installazione (a visione finita)
            if (_pinAsk.onReset(watching: _watching)) _emit('pin');
          case 'exit':
            await c.cmdAck(id, true, 'chiusa');
            _emit('exit');
          default:
            await c.cmdAck(id, false, 'comando sconosciuto');
        }
      } catch (e) {
        await c.cmdAck(id, false, e.toString());
      }
    }
  }

  void _emit(String kind) => uiCommand.value = UiCommand(kind, ++_seq);

  static Map<String, String> _decode(String? raw) {
    if (raw == null || raw.isEmpty) return const {};
    try {
      final j = jsonDecode(raw);
      if (j is Map) return {for (final e in j.entries) e.key.toString(): e.value.toString()};
    } catch (_) {}
    return const {};
  }

  @override
  void dispose() {
    _disposed = true;
    _life?.dispose();
    _poll?.cancel();
    _beat?.cancel();
    _resumeTimer?.cancel();
    _refresh?.cancel();
    dnsBadge.dispose();
    uiCommand.dispose();
    super.dispose();
  }
}

/// Collegamento al fornitore.
final panelProvider = ChangeNotifierProvider<PanelService>((ref) {
  final s = PanelService(ref, ref.watch(prefsProvider));
  ref.onDispose(s.dispose);
  return s;
});

/// Chiude l'app (comando «Chiudi» del fornitore).
Future<void> exitApp() => SystemNavigator.pop();
