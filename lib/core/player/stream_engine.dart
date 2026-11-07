import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../db/kairos_db.dart';
import '../models/models.dart';

enum EngineState { idle, connecting, buffering, playing, reconnecting, ended, failed }

/// Classe della linea (Kairos Adaptive v1): misurata dal lettore, salvata con timestamp.
enum LineClass { weak, normal, good }

class EngineStatus {
  const EngineStatus({
    required this.state,
    this.channel,
    this.attempt = 0,
    this.message,
    this.health = const StreamHealth(),
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.isLive = true,
    this.audioTracks = const [],
    this.subtitleTracks = const [],
  });

  final EngineState state;
  final Channel? channel;
  final int attempt;
  final String? message;
  final StreamHealth health;
  final Duration position;
  final Duration duration;
  final bool isLive;
  final List<AudioTrack> audioTracks;
  final List<SubtitleTrack> subtitleTracks;

  /// [message] resta finché non viene sostituito o azzerato con [clearMessage] (non a ogni tick).
  EngineStatus copyWith({
    EngineState? state,
    Channel? channel,
    int? attempt,
    String? message,
    bool clearMessage = false,
    StreamHealth? health,
    Duration? position,
    Duration? duration,
    bool? isLive,
    List<AudioTrack>? audioTracks,
    List<SubtitleTrack>? subtitleTracks,
  }) =>
      EngineStatus(
        state: state ?? this.state,
        channel: channel ?? this.channel,
        attempt: attempt ?? this.attempt,
        message: clearMessage ? null : (message ?? this.message),
        health: health ?? this.health,
        position: position ?? this.position,
        duration: duration ?? this.duration,
        isLive: isLive ?? this.isLive,
        audioTracks: audioTracks ?? this.audioTracks,
        subtitleTracks: subtitleTracks ?? this.subtitleTracks,
      );
}

/// Profilo buffer scelto dal cliente o imposto dal pannello: modula la classe linea misurata
/// («Veloce» solo con linea good e in diretta; «Stabile» = valori della classe weak).
enum BufferProfile { lowLatency, balanced, stable }

/// Motore di riproduzione "antifragile" (Kairos Adaptive v1 su libmpv).
///
/// Adattività:
///  - ogni secondo misura cache-speed, buffer, stalli (paused-for-cache), bitrate, frame persi, ttff (hwdec ogni 5 s)
///  - ogni 5 s classifica la linea (weak / normal / good) su una finestra di 60 s con isteresi:
///    si scende subito, si sale dopo 120 s puliti; la classe è salvata (kx_line) e vale 12 h
///  - per classe: cache/readahead, attesa di riempimento, tetti in byte, hls-bitrate, timeout, soglia watchdog
///
/// Stabilità:
///  - un fallimento vero è solo: EOF in diretta, "Failed to open", errori di rete ripetuti, watchdog;
///    il resto (es. "Error decoding audio" sui TS) è diagnostica
///  - recupero senza interrompere per curare: su HLS prima un gradino di qualità in meno, su TS l'alternativa
///    più leggera; cambio sorgente dopo 2 fallimenti distanti ≥ 3 s; backoff 0,5→8 s poi 30 s, massimo 3 cicli
///  - VOD: riapertura sempre dall'ultima posizione buona (−2 s); EOF vero ⇒ stato `ended`
///
/// Velocità:
///  - un solo Player libmpv (e un solo VideoController) riutilizzati: zero cold-start a ogni zapping
///  - live TS con sonda corta (analyzeduration/probesize) = zapping più rapido
class StreamEngine {
  StreamEngine(this._db, {BufferProfile profile = BufferProfile.balanced, SharedPreferences? prefs})
      : _profile = profile,
        _prefs = prefs {
    _line = _loadLine();
    _player = Player(
      configuration: const PlayerConfiguration(
        bufferSize: 64 * 1024 * 1024,
        title: 'Kairos Nova',
        logLevel: MPVLogLevel.warn,
      ),
    );
    _applyCommon();
    unawaited(_applyTier());
    _wire();
    active = this;
  }

  /// Istanza viva (il pannello legge le statistiche senza crearne una nuova).
  static StreamEngine? active;

  static const _kUserAgent = 'KairosNova/1.0';
  static const _kLine = 'kx_line';
  static const _lineDecay = Duration(hours: 12);

  final KairosDb _db;
  final SharedPreferences? _prefs;
  BufferProfile _profile;
  late final Player _player;
  Player get player => _player;
  VideoController? _video;

  /// Un solo VideoController per tutta la vita del motore (uno per schermata = texture mai liberate).
  VideoController get video => _video ??= VideoController(_player,
      configuration: const VideoControllerConfiguration(enableHardwareAcceleration: true));

  final _status = ValueNotifier<EngineStatus>(const EngineStatus(state: EngineState.idle));
  ValueListenable<EngineStatus> get status => _status;

  /// Cresce quando un canale parte davvero (cronologia aggiornata): la Home si ricostruisce solo allora.
  final ValueNotifier<int> playVersion = ValueNotifier<int>(0);

  LineClass _line = LineClass.normal;
  LineClass get line => _line;
  double _lineBps = 0; // banda stimata della linea (bit/s), solo da campioni validi
  DateTime? _lineSavedAt;
  DateTime _cleanSince = DateTime.now(); // da quando non ci sono stalli né segnali di debolezza
  DateTime? _lastEval;
  final _samples = <_Sample>[]; // finestra 60 s
  final _stallLog = <DateTime>[]; // ultimi 10 minuti
  int _stallsTotal = 0;
  bool _pfcPrev = false;

  Channel? _current;
  bool _isLive = true;
  bool _isHls = false;
  String _fmt = '';
  List<Channel>? _alts; // calcolate solo al primo fallimento
  int _altIndex = -1;
  int _attempt = 0; // fallimenti sul link corrente
  int _failures = 0; // fallimenti dall'ultimo periodo stabile (backoff)
  int _cycle = 0; // giri completi su tutte le sorgenti
  int _reconnects = 0;
  bool _hlsStepped = false;
  String? _hlsOverride;
  DateTime? _failedOpenAt; // tentativo di apertura già contato come fallito
  DateTime? _lastNetErr;
  int _netErrs = 0;
  DateTime? _lastNote;
  Timer? _retryTimer;
  Timer? _watchdog;
  Timer? _healthTimer;
  bool _ticking = false;
  int _tickN = 0;
  String _codecRaw = ''; // ultimi video-codec / hwdec-current letti (si rileggono a ogni apertura)
  String _hwdecRaw = '';
  Duration _lastPos = Duration.zero;
  Duration _resumePos = Duration.zero; // ultima posizione buona (VOD), sopravvive alle riaperture
  DateTime? _lastProgress;
  DateTime? _lastPosEmit;
  DateTime? _lastSeekAt;
  DateTime? _openedAt;
  DateTime? _startedAt;
  bool _started = false;
  bool _opening = false;
  int _ttffMs = 0;
  double _curBitrate = 0; // bit/s (video+audio) dell'ultimo tick
  double _brEma = 0; // bitrate medio del link in visione, memorizzato per scegliere la versione più leggera
  bool _disposed = false;
  int _generation = 0;

  final _subs = <StreamSubscription>[];

  // ------------------------------------------------------------- Pubblico

  Future<void> play(Channel c, {Duration? startAt}) async {
    _generation++;
    final gen = _generation;
    _cancelTimers();
    _flushBitrate();
    _current = c;
    _isLive = c.type == ChannelType.live || c.type == ChannelType.radio;
    _isHls = _looksHls(c.url);
    _fmt = '';
    _alts = null;
    _altIndex = -1;
    _attempt = 0;
    _failures = 0;
    _cycle = 0;
    _reconnects = 0;
    _hlsStepped = false;
    _hlsOverride = null;
    _failedOpenAt = null;
    _netErrs = 0;
    _ttffMs = 0;
    _resumePos = startAt ?? Duration.zero;
    _emit(EngineStatus(
        state: EngineState.connecting, channel: c, isLive: _isLive, health: StreamHealth(line: _line.name)));
    await _open(c, gen, startAt: startAt);
  }

  Future<void> stop() async {
    _generation++;
    _cancelTimers();
    _flushBitrate();
    _saveLine();
    _current = null;
    _alts = null;
    try {
      await _player.stop();
    } catch (_) {}
    _emit(const EngineStatus(state: EngineState.idle));
  }

  Future<void> pause() => _player.pause();
  Future<void> resume() => _player.play();

  Future<void> togglePause() async {
    await _player.playOrPause();
  }

  Future<void> seek(Duration d) {
    // durante il seek la posizione non avanza: non è uno stallo
    _lastSeekAt = DateTime.now();
    _lastProgress = _lastSeekAt;
    return _player.seek(d);
  }

  Future<void> setAudioTrack(AudioTrack t) => _player.setAudioTrack(t);
  Future<void> setSubtitleTrack(SubtitleTrack t) => _player.setSubtitleTrack(t);
  Future<void> setRate(double r) => _player.setRate(r);
  Future<void> setVolume(double v) => _player.setVolume(v);

  /// Forza il salto al link alternativo successivo (dal menu "Cambia sorgente").
  Future<void> nextSource() async {
    final c = _current;
    if (c == null) return;
    _generation++;
    final gen = _generation;
    _cancelTimers();
    _flushBitrate();
    final next = _pickAlternative();
    if (next == null) {
      _emit(_status.value.copyWith(message: 'Nessuna sorgente alternativa'));
      return;
    }
    _attempt = 0;
    _emit(_status.value.copyWith(state: EngineState.reconnecting, message: 'Sorgente ${_altIndex + 2}'));
    await _open(next, gen, startAt: _resumeStart());
  }

  void setProfile(BufferProfile p) {
    _profile = p;
    unawaited(_applyTier());
  }

  /// Statistiche per il battito del pannello («Online ora»).
  Map<String, Object?> panelStats() {
    final now = DateTime.now();
    final h = _status.value.health;
    double? dropPct;
    if (_started && _startedAt != null && h.fps > 0) {
      final played = now.difference(_startedAt!).inSeconds;
      if (played > 0) dropPct = (h.droppedFrames * 100 / (h.fps * played)).clamp(0, 100).toDouble();
    }
    return {
      'bw': _lineBps > 0 ? (_lineBps / 1e6 * 100).round() / 100 : null,
      'line': _line.name,
      'stalls10': _stallLog.where((t) => now.difference(t) <= const Duration(minutes: 10)).length,
      'ttff': _ttffMs,
      'fmt': _fmt.isEmpty ? (_isHls ? 'hls' : 'ts') : _fmt,
      'drop': dropPct == null ? null : (dropPct * 10).round() / 10,
    };
  }

  /// Classe linea salvata (con decadimento), per chi non ha un motore in mano.
  static String savedLine(SharedPreferences? p) {
    final raw = p?.getString(_kLine);
    if (raw == null || raw.isEmpty) return LineClass.normal.name;
    try {
      final j = jsonDecode(raw);
      if (j is Map) {
        final ts = j['ts'] is num ? (j['ts'] as num).toInt() : 0;
        if (DateTime.now().millisecondsSinceEpoch - ts > _lineDecay.inMilliseconds) return LineClass.normal.name;
        final l = (j['line'] ?? '').toString();
        if (LineClass.values.any((e) => e.name == l)) return l;
      }
    } catch (_) {}
    return LineClass.normal.name;
  }

  Future<void> dispose() async {
    _disposed = true;
    if (identical(active, this)) active = null;
    _cancelTimers();
    _flushBitrate();
    _saveLine();
    for (final s in _subs) {
      await s.cancel();
    }
    await _player.dispose();
    _status.dispose();
    playVersion.dispose();
  }

  // ------------------------------------------------------------- Classe linea

  LineClass _loadLine() {
    final raw = _prefs?.getString(_kLine);
    if (raw == null || raw.isEmpty) return LineClass.normal;
    try {
      final j = jsonDecode(raw);
      if (j is Map) {
        final bps = j['bps'] is num ? (j['bps'] as num).toDouble() : 0.0;
        if (bps > 0) _lineBps = bps;
        final ts = j['ts'] is num ? (j['ts'] as num).toInt() : 0;
        // decadimento: dopo 12 h senza nuove misure si riparte da normal
        if (DateTime.now().millisecondsSinceEpoch - ts > _lineDecay.inMilliseconds) return LineClass.normal;
        return LineClass.values.firstWhere((e) => e.name == j['line'], orElse: () => LineClass.normal);
      }
    } catch (_) {}
    return LineClass.normal;
  }

  void _saveLine() {
    final p = _prefs;
    if (p == null) return;
    _lineSavedAt = DateTime.now();
    p.setString(_kLine,
        jsonEncode({'line': _line.name, 'ts': _lineSavedAt!.millisecondsSinceEpoch, 'bps': _lineBps.round()}));
  }

  void _setLine(LineClass l) {
    if (l == _line) return;
    _line = l;
    _saveLine();
    unawaited(_applyTier());
    _emit(_status.value.copyWith(health: _status.value.health.copyWith(line: l.name)));
  }

  /// Classe effettiva per le opzioni mpv: il profilo del cliente/pannello modula quella misurata.
  LineClass get _tier => _profile == BufferProfile.stable ? LineClass.weak : _line;

  /// «Veloce» ha effetto solo con linea good e in diretta.
  bool get _fast => _profile == BufferProfile.lowLatency && _line == LineClass.good && _isLive;

  // (live, VOD) per classe
  static const Map<LineClass, (int, int)> _cacheSecs = {
    LineClass.weak: (20, 60),
    LineClass.normal: (12, 30),
    LineClass.good: (6, 20),
  };
  static const Map<LineClass, (double, double)> _pauseWait = {
    LineClass.weak: (3.0, 5.0),
    LineClass.normal: (1.5, 2.0),
    LineClass.good: (0.5, 1.0),
  };
  // (avanti, indietro) in MiB
  static const Map<LineClass, (int, int)> _maxBytes = {
    LineClass.weak: (32, 8),
    LineClass.normal: (48, 16),
    LineClass.good: (64, 32),
  };
  static const Map<LineClass, int> _netTimeout = {LineClass.weak: 20, LineClass.normal: 15, LineClass.good: 10};
  static const Map<LineClass, int> _stallSecs = {LineClass.weak: 25, LineClass.normal: 15, LineClass.good: 8};

  int get _cacheTarget {
    if (_fast) return 4;
    final s = _cacheSecs[_tier]!;
    return _isLive ? s.$1 : s.$2;
  }

  String _hlsBitrateFor(LineClass t) => switch (t) {
        LineClass.weak => _lineBps > 0 ? '${(_lineBps * 0.7).round()}' : '1500000',
        LineClass.normal => _lineBps > 0 ? '${(_lineBps * 0.8).round()}' : 'max',
        LineClass.good => 'max',
      };

  // ------------------------------------------------------------- Opzioni mpv

  /// Opzioni comuni a tutte le classi (una volta sola).
  void _applyCommon() {
    final native = _player.platform;
    if (native is! NativePlayer) return;
    native.setProperty('cache', 'yes');
    native.setProperty('cache-on-disk', 'no');
    native.setProperty('cache-pause', 'yes');
    native.setProperty('cache-pause-initial', 'yes');
    native.setProperty('hwdec', 'auto-safe');
    native.setProperty('vd-lavc-dr', 'yes');
    native.setProperty('video-sync', 'audio');
    native.setProperty('tls-verify', 'no');
    native.setProperty('user-agent', _kUserAgent);
    // media_kit imposta demuxer-lavf-o (seg_max_retry, protocol_whitelist…) e non tocca stream-lavf-o: qui si
    // AGGIUNGE con `change-list … append` (il suffisso -append non passa dall'interfaccia delle proprietà).
    for (final kv in const ['reconnect=1', 'reconnect_streamed=1', 'reconnect_delay_max=4']) {
      native.command(['change-list', 'stream-lavf-o', 'append', kv]);
    }
  }

  /// Opzioni per classe (runtime dove mpv lo consente: cache, readahead, tetti, cache-pause-wait;
  /// network-timeout e hls-bitrate valgono dal prossimo open).
  Future<void> _applyTier() async {
    final native = _player.platform;
    if (native is! NativePlayer || _disposed) return;
    final t = _tier;
    final secs = _cacheTarget;
    final w = _pauseWait[t]!;
    final wait = _fast ? 0.5 : (_isLive ? w.$1 : w.$2);
    final (fwd, back) = _maxBytes[t]!;
    await native.setProperty('cache-secs', '$secs');
    await native.setProperty('demuxer-readahead-secs', '$secs');
    await native.setProperty('cache-pause-wait', '$wait');
    await native.setProperty('demuxer-max-bytes', '${fwd * 1024 * 1024}');
    await native.setProperty('demuxer-max-back-bytes', '${back * 1024 * 1024}');
    await native.setProperty('network-timeout', '${_netTimeout[t]}');
    await native.setProperty('hls-bitrate', _hlsOverride ?? _hlsBitrateFor(t));
  }

  // ------------------------------------------------------------- Apertura

  Future<void> _open(Channel c, int gen, {Duration? startAt}) async {
    if (_disposed || gen != _generation) return;
    _openedAt = DateTime.now();
    _lastPos = Duration.zero;
    _lastProgress = DateTime.now();
    _started = false;
    _startedAt = null;
    _pfcPrev = false;
    _opening = true;
    _codecRaw = '';
    _hwdecRaw = '';

    final native = _player.platform;
    if (native is NativePlayer) {
      await _applyTier();
      // User-Agent del canale anche come opzione (non viene azzerato dagli hook di media_kit)
      final h = c.headers;
      final ua = h == null ? null : (h['User-Agent'] ?? h['user-agent']);
      await native.setProperty('user-agent', ua == null || ua.isEmpty ? _kUserAgent : ua);
      // live TS: sonda corta = zapping più rapido; altrove i default di ffmpeg (0 = default; probesize 5 MB)
      final liveTs = _isLive && !_isHls;
      await native.setProperty('demuxer-lavf-analyzeduration', liveTs ? '1' : '0');
      await native.setProperty('demuxer-lavf-probesize', liveTs ? '1000000' : '5000000');
    }
    if (_disposed || gen != _generation) {
      _opening = false;
      return;
    }

    try {
      // Header per canale via Media.httpHeaders: media_kit li applica nell'hook on_load e li azzera in on_unload
      // (impostarli con setProperty('http-header-fields') si perde dal secondo zap in poi).
      await _player.open(Media(c.url, httpHeaders: c.headers, start: startAt), play: true);
    } catch (e) {
      _opening = false;
      if (gen == _generation && !_disposed) _onFailure('Apertura fallita: $e');
      return;
    }
    _opening = false;
    if (_disposed || gen != _generation) return;
    _startWatchdog();
    _startHealth();
  }

  /// Posizione da cui riaprire: diretta = bordo live; VOD = ultima posizione buona meno 2 s.
  Duration? _resumeStart() {
    if (_isLive) return null;
    if (_resumePos <= const Duration(seconds: 2)) return null;
    return _resumePos - const Duration(seconds: 2);
  }

  static bool _looksHls(String url) {
    final path = Uri.tryParse(url)?.path.toLowerCase() ?? url.toLowerCase();
    return path.endsWith('.m3u8') || url.toLowerCase().contains('.m3u8?');
  }

  // ------------------------------------------------------------- Eventi del player

  void _wire() {
    final s = _player.stream;
    _subs.add(s.buffering.listen((b) {
      if (_opening || _current == null || _disposed) return;
      final st = _status.value.state;
      if (st == EngineState.failed || st == EngineState.ended) return;
      if (!b) {
        if (!_started) {
          _onStarted(); // primo buffering=false dopo l'open = partito davvero
        } else if (st == EngineState.buffering) {
          _emit(_status.value.copyWith(state: EngineState.playing));
        }
        return;
      }
      // b: core-idle scatta anche con la pausa dell'utente, che non è buffering
      if (st == EngineState.playing && _player.state.playing) {
        _emit(_status.value.copyWith(state: EngineState.buffering));
      }
    }));
    _subs.add(s.position.listen((p) {
      if (_opening || _current == null || _disposed) return;
      if (p != _lastPos) {
        _lastPos = p;
        _lastProgress = DateTime.now();
        if (p > Duration.zero) _resumePos = p;
      }
      // la UI riceve la posizione al massimo 4 volte al secondo
      final now = DateTime.now();
      if (_lastPosEmit == null || now.difference(_lastPosEmit!).inMilliseconds >= 250) {
        _lastPosEmit = now;
        _emit(_status.value.copyWith(position: p));
      }
    }));
    _subs.add(s.duration.listen((d) {
      if (_opening || _current == null || _disposed) return;
      _emit(_status.value.copyWith(duration: d, isLive: d == Duration.zero || d.inHours > 20));
    }));
    _subs.add(s.tracks.listen((t) {
      if (_disposed) return;
      _emit(_status.value.copyWith(audioTracks: t.audio, subtitleTracks: t.subtitle));
    }));
    // Lo stream `error` di media_kit è un sottoinsieme dei log di livello error: si classifica da `log`
    // (una sola volta per riga) e si decide cos'è un fallimento vero.
    _subs.add(s.log.listen(_onLog));
    _subs.add(s.completed.listen((done) {
      if (!done || _opening || _current == null || _disposed) return;
      final st = _status.value;
      if (st.state == EngineState.failed || st.state == EngineState.ended) return;
      if (st.isLive) {
        // Un live che "finisce" è una caduta del server: riconnetti.
        _onFailure('Stream interrotto dal server');
        return;
      }
      // VOD: fine vera solo se si è arrivati (quasi) in fondo; altrimenti il server ha chiuso la transcodifica.
      final dur = st.duration.inMilliseconds;
      final pos = math.max(st.position.inMilliseconds, _lastPos.inMilliseconds);
      if (dur > 0 && pos >= dur * 0.9) {
        _cancelTimers();
        _emit(st.copyWith(state: EngineState.ended, position: st.duration));
        return;
      }
      _onFailure('Riproduzione interrotta dal server');
    }));
  }

  void _onStarted() {
    final now = DateTime.now();
    _started = true;
    _startedAt = now;
    _lastProgress = now;
    _pfcPrev = false;
    _ttffMs = _openedAt == null ? 0 : now.difference(_openedAt!).inMilliseconds;
    final c = _current;
    if (c != null) {
      try {
        _db.recordStreamResult(_playingUrl ?? c.url, ok: true, startMs: _ttffMs);
        _db.recordPlay(c);
      } catch (_) {}
      playVersion.value++;
    }
    _emit(_status.value.copyWith(
      state: EngineState.playing,
      clearMessage: true,
      health: _status.value.health.copyWith(latencyMs: _ttffMs, reconnects: _reconnects, line: _line.name),
    ));
  }

  static final _fatalRe = RegExp(
      r'Failed to open|Could not open|Failed to recognize|No such file|unsafe URL|Protocol not found|not found',
      caseSensitive: false);
  static final _netRe = RegExp(
      r'^tcp:|Connection (refused|reset|timed out)|Failed to resolve|Server returned [45]\d\d|HTTP error|'
      r'Network is unreachable|Input/output error|I/O error|End of file|Broken pipe',
      caseSensitive: false);

  void _onLog(PlayerLog l) {
    if (l.level != 'error' || _current == null || _disposed || _opening) return;
    final st = _status.value.state;
    if (st == EngineState.failed || st == EngineState.ended) return;
    final t = l.text;
    final isFile = l.prefix == 'cplayer' || l.prefix == 'stream' || l.prefix == 'file';
    if (isFile && _fatalRe.hasMatch(t)) {
      if (!_started) {
        _onFailure(_short(t)); // URL morto all'apertura
        return;
      }
      // a visione avviata è un sintomo di rete: conta come errore rete (sotto)
    } else if (!_netRe.hasMatch(t)) {
      // decodifica audio/video sui TS, pacchetti corrotti, PPS mancanti…: solo diagnostica
      _note(t);
      return;
    }
    // errori di rete: fallimento solo se ripetuti (≥ 2 entro 3 s); il singolo lo copre ffmpeg (reconnect) o il watchdog
    final now = DateTime.now();
    if (_lastNetErr != null && now.difference(_lastNetErr!) <= const Duration(seconds: 3)) {
      _netErrs++;
    } else {
      _netErrs = 1;
    }
    _lastNetErr = now;
    if (_netErrs >= 2) {
      _netErrs = 0;
      _onFailure('Errore di rete');
      return;
    }
    _note(t);
  }

  /// Diagnostica (overlay): al massimo una riga al secondo, senza URL (possono contenere credenziali).
  void _note(String text) {
    final now = DateTime.now();
    if (_lastNote != null && now.difference(_lastNote!).inMilliseconds < 1000) return;
    _lastNote = now;
    _emit(_status.value.copyWith(health: _status.value.health.copyWith(message: _short(text))));
  }

  static final _urlRe = RegExp(r'https?://\S+');
  static final _spacesRe = RegExp(r'\s+');

  static String _short(String t) {
    final s = t.replaceAll(_urlRe, '…').replaceAll(_spacesRe, ' ').trim();
    return s.length > 90 ? '${s.substring(0, 90)}…' : s;
  }

  String? get _playingUrl {
    final idx = _altIndex;
    final alts = _alts;
    if (idx < 0 || alts == null) return _current?.url;
    return idx < alts.length ? alts[idx].url : _current?.url;
  }

  // ------------------------------------------------------------- Watchdog

  void _startWatchdog() {
    _watchdog?.cancel();
    _watchdog = Timer.periodic(const Duration(seconds: 2), (_) {
      if (_current == null || _disposed || _opening) return;
      final st = _status.value.state;
      if (st == EngineState.failed || st == EngineState.ended || st == EngineState.idle) return;
      final now = DateTime.now();
      if (!_started) {
        final limit = _netTimeout[_tier]! + 5;
        if (_openedAt != null && now.difference(_openedAt!).inSeconds > limit) {
          _onFailure('Il server non risponde');
        }
        return;
      }
      // la pausa dell'utente e la fine del file non sono stalli
      if (!_player.state.playing || _player.state.completed) {
        _lastProgress = now;
        return;
      }
      if (_lastProgress != null && now.difference(_lastProgress!).inSeconds > _stallSecs[_tier]!) {
        _onFailure('Stream bloccato, riavvio…');
      }
    });
  }

  // ------------------------------------------------------------- Misure (ogni secondo)

  void _startHealth() {
    _healthTimer?.cancel();
    _healthTimer = Timer.periodic(const Duration(seconds: 1), (_) => unawaited(_tick()));
  }

  Future<void> _tick() async {
    final native = _player.platform;
    if (native is! NativePlayer || _current == null || _disposed || _ticking || _opening) return;
    _ticking = true;
    try {
      Future<double> prop(String name) async => double.tryParse(await native.getProperty(name)) ?? 0.0;
      final speedB = await prop('cache-speed'); // byte/s dalla rete
      final cacheS = await prop('demuxer-cache-duration');
      final pfc = (await native.getProperty('paused-for-cache')) == 'yes';
      final vbr = await prop('video-bitrate'); // bit/s
      final abr = await prop('audio-bitrate');
      final w = await prop('width');
      final h = await prop('height');
      final fps = await prop('estimated-vf-fps');
      final drop = await prop('frame-drop-count');
      // codec e decoder cambiano solo all'apertura (o se mpv ripiega sul software) e servono solo alla
      // diagnostica: riletti ogni 5 s invece che ogni secondo (due chiamate sincrone a mpv in meno al secondo)
      if (_codecRaw.isEmpty || _tickN % 5 == 0) {
        _codecRaw = await native.getProperty('video-codec');
        _hwdecRaw = await native.getProperty('hwdec-current');
      }
      _tickN++;
      final codec = _codecRaw;
      final hwdec = _hwdecRaw;
      if (_fmt.isEmpty) {
        final ff = await native.getProperty('file-format');
        if (ff.isNotEmpty) {
          _fmt = ff.contains('hls') ? 'hls' : (ff.contains('mpegts') ? 'ts' : ff.split(',').first);
          if (_fmt == 'hls') _isHls = true;
        }
      }
      if (_disposed || _current == null || _opening) return;
      final now = DateTime.now();
      final bitrate = vbr + abr;
      _curBitrate = bitrate;
      if (_started && bitrate > 0) _brEma = _brEma == 0 ? bitrate : _brEma * 0.8 + bitrate * 0.2;

      // Stalli: paused-for-cache che scatta a visione avviata (non all'avvio, non subito dopo un seek).
      final afterStart = _started && _startedAt != null && now.difference(_startedAt!).inSeconds >= 4;
      final afterSeek = _lastSeekAt == null || now.difference(_lastSeekAt!).inSeconds >= 3;
      if (pfc && !_pfcPrev && afterStart && afterSeek) {
        _stallLog.add(now);
        _stallsTotal++;
        _cleanSince = now;
      }
      _pfcPrev = pfc;
      _stallLog.removeWhere((t) => now.difference(t) > const Duration(minutes: 10));

      // Campioni di banda: validi solo mentre il cuscinetto si riempie (a cuscinetto pieno mpv legge alla
      // velocità del canale, non della linea). Un TS in diretta arriva comunque al ritmo del canale: non dice
      // quanto è larga la linea, dice solo se la regge (R < 0,9 = il buffer si svuota).
      final tsLive = _isLive && !_isHls;
      final valid = _started && speedB > 0 && bitrate > 0 && cacheS < _cacheTarget * 0.8;
      final speedBits = speedB * 8;
      _samples.add(_Sample(now, speedBits, bitrate, valid));
      _samples.removeWhere((s) => now.difference(s.at) > const Duration(seconds: 60));
      if (valid && !tsLive) {
        _lineBps = _lineBps == 0 ? speedBits : _lineBps * 0.8 + speedBits * 0.2;
      }
      if (_lastEval == null || now.difference(_lastEval!).inSeconds >= 5) {
        _lastEval = now;
        _evaluate(now, tsLive);
      }
      if (_lineSavedAt == null || now.difference(_lineSavedAt!).inSeconds >= 30) _saveLine();

      // 60 s stabili: i contatori di recupero ripartono da zero.
      if (_started && _startedAt != null && now.difference(_startedAt!).inSeconds >= 60 &&
          (_failures > 0 || _attempt > 0 || _cycle > 0 || _hlsStepped)) {
        _failures = 0;
        _attempt = 0;
        _cycle = 0;
        _hlsStepped = false;
        _hlsOverride = null;
      }

      final st = _status.value;
      _emit(st.copyWith(
        health: st.health.copyWith(
          bufferSeconds: cacheS,
          bitrateKbps: (bitrate / 1000).round(),
          width: w.round(),
          height: h.round(),
          fps: fps,
          droppedFrames: drop.round(),
          reconnects: _reconnects,
          latencyMs: _started ? _ttffMs : (_openedAt == null ? 0 : now.difference(_openedAt!).inMilliseconds),
          codec: codec.split(' ').first,
          speedKbps: (speedBits / 1000).round(),
          stalls: _stallsTotal,
          hwdec: hwdec == 'no' ? '' : hwdec,
          line: _line.name,
          fmt: _fmt,
        ),
      ));
    } catch (_) {
      // proprietà non disponibili in questo istante: si riprova al prossimo tick
    } finally {
      _ticking = false;
    }
  }

  /// Classe linea su finestra 60 s: weak se R < 1,2 (TS live: < 0,9) o ≥ 2 stalli/min; good se R ≥ 2,5 e
  /// 0 stalli per 2 min; normal altrimenti. Si scende subito, si sale dopo 120 s puliti.
  void _evaluate(DateTime now, bool tsLive) {
    final valid = _samples.where((s) => s.valid).toList();
    double? r;
    if (valid.length >= 5) {
      var sum = 0.0;
      for (final s in valid) {
        sum += s.speedBps / s.bitrateBps;
      }
      r = sum / valid.length;
    }
    final stalls1m = _stallLog.where((t) => now.difference(t) <= const Duration(seconds: 60)).length;
    final weak = stalls1m >= 2 || (r != null && r < (tsLive ? 0.9 : 1.2));
    if (weak) _cleanSince = now;
    final cleanFor = now.difference(_cleanSince);
    final good = r != null && r >= 2.5 && stalls1m == 0 && cleanFor >= const Duration(minutes: 2);
    final target = weak ? LineClass.weak : (good ? LineClass.good : LineClass.normal);
    if (target.index < _line.index) {
      _setLine(target);
    } else if (target.index > _line.index && cleanFor >= const Duration(minutes: 2)) {
      _setLine(target);
    }
  }

  // ------------------------------------------------------------- Fallimenti e recupero

  /// Fallimento accertato: EOF in diretta, "Failed to open", errori di rete ripetuti, watchdog.
  void _onFailure(String reason) {
    final c = _current;
    if (c == null || _disposed) return;
    final st = _status.value.state;
    if (st == EngineState.failed || st == EngineState.ended) return;
    // Debounce: un URL morto produce 2-3 eventi in fila (log, EOF, watchdog). Si conta UN fallimento per tentativo
    // di apertura; una riconnessione già in attesa assorbe il resto.
    if (_retryTimer?.isActive == true || _opening) return;
    final openedAt = _openedAt;
    if (openedAt != null && _failedOpenAt == openedAt) return;
    _failedOpenAt = openedAt;
    final gen = _generation;
    final wasStarted = _started;
    final failedUrl = _playingUrl ?? c.url;
    _watchdog?.cancel();
    _healthTimer?.cancel();
    _flushBitrate();
    try {
      _db.recordStreamResult(failedUrl, ok: false);
    } catch (_) {}
    _attempt++; // cresce al massimo di 1 per fallimento
    _failures++;
    _reconnects++;

    Channel target = _altIndex < 0 ? c : (_alts?[_altIndex] ?? c);
    String? label;
    // backoff 0,5 → 1 → 2 → 4 → 8 s, poi 30 s
    final shift = math.max(0, math.min(_failures - 1, 4));
    var delayMs = _failures > 5 ? 30000 : math.min(500 << shift, 8000);

    if (_isHls && wasStarted && !_hlsStepped) {
      // HLS partito e poi caduto: prima un gradino di qualità in meno, poi eventualmente la sorgente
      _stepHlsDown();
      label = 'qualità ridotta';
    } else if (_attempt >= 2) {
      // 2 fallimenti (distanti ≥ 3 s) sullo stesso link: alternativa. Su TS caduto a visione avviata, la più leggera.
      final alt = _pickAlternative(lighter: wasStarted && !_isHls);
      if (alt != null) {
        target = alt;
        _attempt = 1;
        label = 'Sorgente ${_altIndex + 2}';
      } else {
        // giro completo: si ricomincia dal link principale dopo 30 s, al massimo 3 cicli
        _cycle++;
        if (_cycle > 3) {
          _fail('Canale non disponibile al momento');
          return;
        }
        _altIndex = -1;
        target = c;
        _attempt = 1;
        delayMs = 30000;
        label = 'nuovo giro $_cycle';
      }
    }

    _emit(_status.value.copyWith(
      state: EngineState.reconnecting,
      attempt: _attempt,
      message: label == null ? '$reason · tentativo $_attempt' : '$reason · $label',
    ));
    final t = target;
    _retryTimer = Timer(Duration(milliseconds: delayMs), () {
      if (gen != _generation || _disposed) return;
      _open(t, gen, startAt: _resumeStart());
    });
  }

  /// Stato terminale: timer fermi, la UI offre «Riprova» e «Altra sorgente».
  void _fail(String msg) {
    _cancelTimers();
    _saveLine();
    _emit(_status.value.copyWith(state: EngineState.failed, attempt: _attempt, message: msg));
  }

  /// HLS: tetto un gradino sotto il bitrate in uso (vale dal prossimo open).
  void _stepHlsDown() {
    _hlsStepped = true;
    final base = _curBitrate > 0 ? _curBitrate : (_lineBps > 0 ? _lineBps * 0.8 : 3000000);
    _hlsOverride = '${(base * 0.8).round()}';
  }

  Channel? _pickAlternative({bool lighter = false}) {
    var alts = _alts ??= _loadAlternatives();
    if (_altIndex + 1 >= alts.length) return null;
    if (lighter) {
      // fra le alternative non ancora provate, prima quella col bitrate (storico o dal nome) più basso
      final rest = alts.sublist(_altIndex + 1)..sort((a, b) => _kbpsOf(a).compareTo(_kbpsOf(b)));
      alts = [...alts.take(_altIndex + 1), ...rest];
      _alts = alts;
    }
    _altIndex++;
    return alts[_altIndex];
  }

  /// Alternative calcolate solo quando servono (prima non costano nulla all'avvio del canale).
  List<Channel> _loadAlternatives() {
    final c = _current;
    if (c == null) return const [];
    try {
      final alts = _db.alternatives(c, limit: 8);
      alts.sort((a, b) => _db.reliability(b.url).compareTo(_db.reliability(a.url)));
      return alts;
    } catch (_) {
      return const [];
    }
  }

  int _kbpsOf(Channel ch) {
    try {
      final k = _db.knownKbps(ch.url);
      if (k > 0) return k;
    } catch (_) {}
    return _qualityKbps(ch.name);
  }

  static final _q4kRe = RegExp(r'\b(4K|UHD|2160)');
  static final _qFhdRe = RegExp(r'\b(FHD|1080)');
  static final _qSdRe = RegExp(r'\b(SD|576|480)\b');

  /// Stima dal nome quando non c'è storia: 4K/UHD → FHD → HD → SD.
  static int _qualityKbps(String name) {
    final n = name.toUpperCase();
    if (_q4kRe.hasMatch(n)) return 16000;
    if (_qFhdRe.hasMatch(n)) return 8000;
    if (_qSdRe.hasMatch(n)) return 1500;
    return 4000; // HD o ignoto
  }

  /// Memorizza il bitrate medio del link appena visto (serve a scegliere la versione più leggera).
  void _flushBitrate() {
    final url = _playingUrl;
    if (_brEma > 0 && url != null) {
      try {
        _db.recordStreamBitrate(url, (_brEma / 1000).round());
      } catch (_) {}
    }
    _brEma = 0;
  }

  void _cancelTimers() {
    _retryTimer?.cancel();
    _watchdog?.cancel();
    _healthTimer?.cancel();
  }

  void _emit(EngineStatus s) {
    if (!_disposed) _status.value = s;
  }
}

class _Sample {
  const _Sample(this.at, this.speedBps, this.bitrateBps, this.valid);
  final DateTime at;
  final double speedBps;
  final double bitrateBps;
  final bool valid;
}
