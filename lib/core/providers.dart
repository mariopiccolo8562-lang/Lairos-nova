import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'db/kairos_db.dart';
import 'download/download_manager.dart';
import 'm3u/import_service.dart';
import 'models/models.dart';
import 'player/stream_engine.dart';
import 'update/app_updater.dart';

// ------------------------------------------------------------------ Infra

final dbProvider = Provider<KairosDb>((ref) => throw UnimplementedError('override in main'));
final prefsProvider = Provider<SharedPreferences>((ref) => throw UnimplementedError());

final importServiceProvider =
    Provider<ImportService>((ref) => ImportService(ref.watch(dbProvider).path));

final engineProvider = Provider<StreamEngine>((ref) {
  final profile = ref.read(settingsProvider).bufferProfile;
  final engine = StreamEngine(ref.watch(dbProvider), profile: profile, prefs: ref.read(prefsProvider));
  // «Continua a guardare» si aggiorna quando un canale parte davvero, non a ogni tick di posizione
  final pv = ref.read(playVersionProvider.notifier);
  void onPlay() => Future.microtask(() => pv.state++);
  engine.playVersion.addListener(onPlay);
  ref.onDispose(() {
    engine.playVersion.removeListener(onPlay);
    engine.dispose();
  });
  return engine;
});

final downloadManagerProvider = Provider<DownloadManager>((ref) {
  // la visione ha la precedenza: i download si fermano con un lettore aperto e riprendono (Range) alla chiusura
  final m = DownloadManager(ref.watch(dbProvider), watching: () => ref.read(watchingProvider) > 0);
  ref.listen<int>(watchingProvider, (_, n) => m.onWatchingChanged(n > 0));
  m.init();
  ref.onDispose(m.dispose);
  return m;
});

/// Stato del motore come stream (per ValueListenableBuilder usare engine.status).
final engineStatusProvider = StreamProvider<EngineStatus>((ref) {
  final engine = ref.watch(engineProvider);
  final ctrl = StreamController<EngineStatus>();
  void l() => ctrl.add(engine.status.value);
  engine.status.addListener(l);
  ctrl.add(engine.status.value);
  ref.onDispose(() {
    engine.status.removeListener(l);
    ctrl.close();
  });
  return ctrl.stream;
});

// ------------------------------------------------------------------ Settings

class Settings {
  const Settings({
    this.bufferProfile = BufferProfile.balanced,
    this.parentalPin,
    this.hiddenGroups = const {},
    this.autoplayLast = true,
    this.showHealthOverlay = false,
    this.gridColumns = 0, // 0 = auto
    this.epgUrlOverride,
    this.tvMode = false,
    this.preferredAudioLang = 'ita',
    this.parentalOn = true,
    this.pinLater = 0,
  });

  final BufferProfile bufferProfile;
  final String? parentalPin;
  final Set<String> hiddenGroups;
  final bool autoplayLast;
  final bool showHealthOverlay;
  final int gridColumns;
  final String? epgUrlOverride;
  final bool tvMode;
  final String preferredAudioLang;
  /// Controllo genitori attivo (di serie sì). [parentalPin] vuoto = PIN iniziale 0000; [pinLater] = ultimo rinvio della scelta del PIN.
  final bool parentalOn;
  final int pinLater;
  bool get pinIsDefault => parentalPin == null || parentalPin!.isEmpty;
  bool checkPin(String p) => p.trim() == (pinIsDefault ? '0000' : parentalPin);

  Settings copyWith({
    BufferProfile? bufferProfile,
    String? parentalPin,
    bool clearPin = false,
    Set<String>? hiddenGroups,
    bool? autoplayLast,
    bool? showHealthOverlay,
    int? gridColumns,
    String? epgUrlOverride,
    bool? tvMode,
    String? preferredAudioLang,
    bool? parentalOn,
    int? pinLater,
  }) =>
      Settings(
        bufferProfile: bufferProfile ?? this.bufferProfile,
        parentalPin: clearPin ? null : (parentalPin ?? this.parentalPin),
        hiddenGroups: hiddenGroups ?? this.hiddenGroups,
        autoplayLast: autoplayLast ?? this.autoplayLast,
        showHealthOverlay: showHealthOverlay ?? this.showHealthOverlay,
        gridColumns: gridColumns ?? this.gridColumns,
        epgUrlOverride: epgUrlOverride ?? this.epgUrlOverride,
        tvMode: tvMode ?? this.tvMode,
        preferredAudioLang: preferredAudioLang ?? this.preferredAudioLang,
        parentalOn: parentalOn ?? this.parentalOn,
        pinLater: pinLater ?? this.pinLater,
      );
}

class SettingsNotifier extends Notifier<Settings> {
  @override
  Settings build() => _imposed(_own(ref.watch(prefsProvider)));

  /// Impostazioni scelte dal cliente (salvate sul dispositivo).
  Settings _own(SharedPreferences p) {
    return Settings(
      bufferProfile: BufferProfile.values[p.getInt('buffer') ?? 1],
      parentalPin: p.getString('pin'),
      hiddenGroups: (p.getStringList('hidden') ?? const []).toSet(),
      autoplayLast: p.getBool('autoplay') ?? true,
      showHealthOverlay: p.getBool('health') ?? false,
      gridColumns: p.getInt('cols') ?? 0,
      epgUrlOverride: p.getString('epg'),
      tvMode: p.getBool('tv') ?? false,
      preferredAudioLang: p.getString('lang') ?? 'ita',
      parentalOn: p.getBool('parental_on') ?? true,
      pinLater: p.getInt('pin_later') ?? 0,
    );
  }

  /// Voci imposte dal fornitore nel pannello Kairos Control (controllo remoto, salvate in `kx_rc` dal PanelService):
  /// vincono su quelle scelte qui, che restano salvate e tornano valide quando il fornitore libera la voce.
  Map<String, String> remote() {
    try {
      final raw = ref.read(prefsProvider).getString('kx_rc') ?? '';
      final d = raw.isEmpty ? null : jsonDecode(raw);
      if (d is Map) return {for (final e in d.entries) if (e.value != null && e.value.toString().isNotEmpty) e.key.toString(): e.value.toString()};
    } catch (_) {}
    return const {};
  }
  bool imposed(String key) => remote().containsKey(key);
  Settings _imposed(Settings s) {
    final rc = remote();
    if (rc.isEmpty) return s;
    return s.copyWith(
      bufferProfile: switch (rc['p.buffer']) { 'fast' => BufferProfile.lowLatency, 'balanced' => BufferProfile.balanced, 'stable' => BufferProfile.stable, _ => null },
      tvMode: switch (rc['tvmode']) { 'on' => true, 'off' => false, _ => null },
    );
  }
  /// Il pannello ha cambiato le voci imposte: si riapplicano sopra le scelte del cliente.
  void remoteChanged() {
    state = _imposed(_own(ref.read(prefsProvider)));
    ref.read(engineProvider).setProfile(state.bufferProfile);
  }

  void update(Settings Function(Settings) fn) {
    final p = ref.read(prefsProvider);
    // la modifica si applica alle scelte del cliente (non a quelle imposte dal fornitore), e si salva
    final own = fn(_own(p));
    p.setInt('buffer', own.bufferProfile.index);
    own.parentalPin == null ? p.remove('pin') : p.setString('pin', own.parentalPin!);
    p.setStringList('hidden', own.hiddenGroups.toList());
    p.setBool('autoplay', own.autoplayLast);
    p.setBool('health', own.showHealthOverlay);
    p.setInt('cols', own.gridColumns);
    own.epgUrlOverride == null ? p.remove('epg') : p.setString('epg', own.epgUrlOverride!);
    p.setBool('tv', own.tvMode);
    p.setString('lang', own.preferredAudioLang);
    p.setBool('parental_on', own.parentalOn);
    p.setInt('pin_later', own.pinLater);
    state = _imposed(own);
    ref.read(engineProvider).setProfile(state.bufferProfile);
  }
}

final settingsProvider = NotifierProvider<SettingsNotifier, Settings>(SettingsNotifier.new);

/// Controllo genitori: PIN già inserito in questa apertura (i contenuti protetti restano aperti fino alla chiusura).
final parentalUnlockedProvider = StateProvider<bool>((ref) => false);

// ------------------------------------------------------------------ Aggiornamenti

/// Cresce quando il fornitore chiede «Riavvia l'app»: router e interfaccia si ricreano da zero.
final appGenerationProvider = StateProvider<int>((ref) => 0);

/// Schermate di visione aperte (player, multiview): niente download in background né finestre.
final watchingProvider = StateProvider<int>((ref) => 0);

/// Aggiornamento dell'app (feed della release, politica del fornitore, download in background, installazione).
final appUpdaterProvider = ChangeNotifierProvider<AppUpdater>((ref) {
  final u = AppUpdater(ref.watch(prefsProvider), watching: () => ref.read(watchingProvider) > 0);
  ref.onDispose(u.dispose);
  return u;
});

// ------------------------------------------------------------------ Dati

/// Contatore che invalida le query dopo un import.
final dataVersionProvider = StateProvider<int>((ref) => 0);

final playlistsProvider = Provider<List<Playlist>>((ref) {
  ref.watch(dataVersionProvider);
  return ref.watch(dbProvider).playlists();
});

final activePlaylistIdProvider = StateProvider<int?>((ref) {
  final p = ref.watch(prefsProvider).getInt('active_pl');
  final all = ref.watch(playlistsProvider);
  if (p != null && all.any((e) => e.id == p)) return p;
  return all.isEmpty ? null : all.first.id;
});

final groupsProvider = Provider.family<List<ChannelGroup>, ChannelType>((ref, type) {
  ref.watch(dataVersionProvider);
  final pl = ref.watch(activePlaylistIdProvider);
  final hidden = ref.watch(settingsProvider).hiddenGroups;
  return ref
      .watch(dbProvider)
      .groups(playlistId: pl, type: type)
      .where((g) => !hidden.contains(g.name))
      .toList();
});

class ChannelQuery {
  const ChannelQuery({this.type, this.group, this.playlistId});
  final ChannelType? type;
  final String? group;
  final int? playlistId;

  @override
  bool operator ==(Object o) =>
      o is ChannelQuery && o.type == type && o.group == group && o.playlistId == playlistId;
  @override
  int get hashCode => Object.hash(type, group, playlistId);
}

/// Sorgente paginata per liste virtualizzate: tiene in RAM al massimo
/// ~2.000 canali (pagine LRU da 200), qualunque sia la dimensione della lista.
class PagedChannels extends ChangeNotifier {
  PagedChannels(this._db, this.query) {
    total = _db.channelCount(
        playlistId: query.playlistId, type: query.type, group: query.group);
  }

  final KairosDb _db;
  final ChannelQuery query;
  late final int total;
  static const pageSize = 200;
  static const maxPages = 10;

  final _pages = <int, List<Channel>>{};
  final _order = <int>[];
  final _loading = <int>{};

  Channel? at(int index) {
    final page = index ~/ pageSize;
    final list = _pages[page];
    if (list != null) {
      _touch(page);
      final i = index % pageSize;
      return i < list.length ? list[i] : null;
    }
    _load(page);
    return null;
  }

  void _load(int page) {
    if (_loading.contains(page)) return;
    _loading.add(page);
    // Lettura sincrona: SQLite con indice risponde in <2ms per 200 righe.
    // Differita al prossimo frame per non bloccare il build corrente.
    scheduleMicrotask(() {
      final rows = _db.channelsPage(
        playlistId: query.playlistId,
        type: query.type,
        group: query.group,
        offset: page * pageSize,
        limit: pageSize,
      );
      _pages[page] = rows;
      _touch(page);
      _loading.remove(page);
      while (_order.length > maxPages) {
        _pages.remove(_order.removeAt(0));
      }
      notifyListeners();
    });
  }

  void _touch(int page) {
    _order.remove(page);
    _order.add(page);
  }

  void refreshFavorites() {
    for (final e in _pages.entries) {
      _pages[e.key] = e.value
          .map((c) => c.copyWith(
              isFavorite: _db.channel(c.id)?.isFavorite ?? c.isFavorite))
          .toList();
    }
    notifyListeners();
  }
}

final pagedChannelsProvider =
    ChangeNotifierProvider.family<PagedChannels, ChannelQuery>((ref, q) {
  ref.watch(dataVersionProvider);
  return PagedChannels(ref.watch(dbProvider), q);
});

final favoritesProvider = Provider<List<Channel>>((ref) {
  ref.watch(dataVersionProvider);
  ref.watch(favVersionProvider);
  return ref.watch(dbProvider).favorites();
});
final favVersionProvider = StateProvider<int>((ref) => 0);

/// Cresce a ogni riproduzione registrata in cronologia (il motore all'avvio del canale, il lettore alla chiusura):
/// al posto dello stato del motore, che emette decine di volte al secondo.
final playVersionProvider = StateProvider<int>((ref) => 0);

final recentProvider = Provider<List<Channel>>((ref) {
  ref.watch(dataVersionProvider);
  ref.watch(playVersionProvider);
  return ref.watch(dbProvider).recent();
});

/// Totale contenuti della lista attiva: COUNT su centinaia di migliaia di righe, calcolato una volta e non a ogni build.
final totalCountProvider = Provider<int>((ref) {
  ref.watch(dataVersionProvider);
  final pl = ref.watch(activePlaylistIdProvider);
  return ref.watch(dbProvider).channelCount(playlistId: pl);
});

final searchQueryProvider = StateProvider<String>((ref) => '');
final searchResultsProvider = Provider<List<Channel>>((ref) {
  final q = ref.watch(searchQueryProvider);
  if (q.trim().length < 2) return const [];
  return ref.watch(dbProvider).search(q);
});

final nowNextProvider = Provider.family<NowNext, String?>((ref, tvgId) {
  ref.watch(epgTickProvider);
  return ref.watch(dbProvider).nowNext(tvgId);
});

/// Tick ogni 60s per aggiornare "in onda ora".
final epgTickProvider = StreamProvider<int>((ref) =>
    Stream.periodic(const Duration(seconds: 60), (i) => i));

// ------------------------------------------------------------------ Azioni

class Actions {
  Actions(this.ref);
  final Ref ref;

  Future<void> importPlaylist(Playlist p, void Function(ImportProgress) onProgress) async {
    final svc = ref.read(importServiceProvider);
    await for (final prog in svc.importPlaylist(p)) {
      onProgress(prog);
      if (prog.error != null) throw Exception(prog.error);
    }
    ref.read(dataVersionProvider.notifier).state++;
    final epg = ref.read(settingsProvider).epgUrlOverride ?? p.epgUrl;
    if (epg != null && epg.isNotEmpty) {
      await for (final prog in svc.importEpg(epg)) {
        onProgress(prog);
      }
      ref.read(dataVersionProvider.notifier).state++;
    }
  }

  void toggleFavorite(Channel c) {
    ref.read(dbProvider).toggleFavorite(c);
    ref.read(favVersionProvider.notifier).state++;
  }

  void setActivePlaylist(int id) {
    ref.read(prefsProvider).setInt('active_pl', id);
    ref.read(activePlaylistIdProvider.notifier).state = id;
  }
}

final actionsProvider = Provider<Actions>((ref) => Actions(ref));
