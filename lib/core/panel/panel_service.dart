import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/models.dart';
import '../player/stream_engine.dart';
import '../providers.dart';
import '../update/app_updater.dart';
import '../xtream/xtream_api.dart';
import 'panel_client.dart';

/// Comando del pannello che tocca l'interfaccia (lo esegue la shell): reload | settings | exit.
class UiCommand {
  const UiCommand(this.kind, this.seq);
  final String kind;
  final int seq;
}

/// Collegamento facoltativo al fornitore (pannello Kairos Control), come le altre app Kairos.
/// - Il cliente comunica il codice KX..-.... al fornitore; appena lo attiva, le sue liste arrivano da sole.
/// - Battito ogni minuto («Online ora», impostazioni imposte, comandi, «Invia aggiornamento»).
/// - Senza collegamento l'app resta libera: liste proprie, aggiornamenti dal feed pubblico.
class PanelService extends ChangeNotifier {
  PanelService(this._ref, this._prefs) {
    final code = _prefs.getString('kx_code') ?? '';
    final secret = _prefs.getString('kx_secret') ?? '';
    if (code.isNotEmpty && secret.isNotEmpty) _identity = PanelIdentity(code, secret);
    _server = _prefs.getString('kx_server') ?? kDefaultPanelUrl;
    _rc = _decode(_prefs.getString('kx_rc'));
    _rcv = _prefs.getString('kx_rcv') ?? '';
    _map = _decode(_prefs.getString('kx_pl_map'));
    _sigs = _decode(_prefs.getString('kx_pl_sig'));
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
  Map<String, String> _rc = const {};
  String _rcv = '';
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

  /// Liste che arrivano dal fornitore (id in Nova).
  Set<int> get providerPlaylistIds => {for (final v in _map.values) int.tryParse(v) ?? -1}..remove(-1);

  // ------------------------------------------------------------------ avvio

  /// Chiamato una volta dalla shell con versione e modello (dalla parte nativa).
  Future<void> start({required String version, required String model}) async {
    _version = version;
    _model = model;
    if (!linked) return;
    _client = _mkClient();
    unawaited(refresh());
    _beat?.cancel();
    _beat = Timer.periodic(const Duration(seconds: 60), (_) => unawaited(heartbeat()));
    _refresh?.cancel();
    _refresh = Timer.periodic(const Duration(hours: 6), (_) => unawaited(refresh()));
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

  /// L'app torna in primo piano: battito subito.
  void onForeground() {
    if (linked && active) unawaited(heartbeat());
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
    _beat ??= Timer.periodic(const Duration(seconds: 60), (_) => unawaited(heartbeat()));
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
      if (s.raw.containsKey('rc')) _applyRc(s.raw['rc'], (s.raw['rcv'] ?? '').toString());
      if (s.active) await _syncPlaylists(s.playlists);
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
    _rcv = '';
    _map = const {};
    _sigs = const {};
    for (final k in ['kx_code', 'kx_secret', 'kx_rc', 'kx_rcv', 'kx_pl_map', 'kx_pl_sig']) {
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

  // ------------------------------------------------------------------ battito e controllo remoto

  Future<void> heartbeat() async {
    final c = _client;
    if (c == null || state == null || !state!.active) return;
    final watching = _ref.read(watchingProvider) > 0;
    final st = _ref.read(engineProvider).status.value;
    final title = watching && st.state == EngineState.playing ? (st.channel?.name ?? '') : '';
    final j = await c.heartbeat(state: watching ? 'playing' : 'idle', title: title, screen: watching ? 'player' : 'home', kickAck: _kickSeen, cfg: {'bgupd': _ref.read(appUpdaterProvider).bgUpdate ? 'on' : 'off'}, rcv: _rcv);
    if (j == null) return;
    if (j['rc'] != null) _applyRc(j['rc'], (j['rcv'] ?? '').toString());
    // «Disconnetti» dal pannello: si conferma e l'app si scollega
    final kick = (j['kick'] is num) ? (j['kick'] as num).toInt() : 0;
    if (kick > 0 && kick != _kickSeen) {
      _kickSeen = kick;
      await c.heartbeat(state: 'idle', kickAck: kick, rcv: _rcv);
      await unlink();
      _emit('relink');
      return;
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
  }

  void _applyRc(Object? raw, String rcv) {
    Map<String, String> next = const {};
    try {
      final d = raw is String ? (raw.isEmpty ? const {} : jsonDecode(raw)) : raw;
      if (d is Map) next = {for (final e in d.entries) if (e.value != null) e.key.toString(): e.value.toString()};
    } catch (_) {}
    if (jsonEncode(next) == jsonEncode(_rc) && rcv == _rcv) return;
    _rc = next;
    _rcv = rcv;
    _prefs.setString('kx_rc', jsonEncode(next));
    _prefs.setString('kx_rcv', rcv);
    _ref.read(appUpdaterProvider).applyRemotePolicy({for (final k in ['bgupd', 'force']) if (next.containsKey(k)) k: next[k]!});
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
              await DefaultCacheManager().emptyCache();
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
    _poll?.cancel();
    _beat?.cancel();
    _refresh?.cancel();
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
