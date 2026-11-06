import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';

import '../db/kairos_db.dart';
import '../models/models.dart';

enum EngineState { idle, connecting, buffering, playing, reconnecting, failed }

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

  EngineStatus copyWith({
    EngineState? state,
    Channel? channel,
    int? attempt,
    String? message,
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
        message: message,
        health: health ?? this.health,
        position: position ?? this.position,
        duration: duration ?? this.duration,
        isLive: isLive ?? this.isLive,
        audioTracks: audioTracks ?? this.audioTracks,
        subtitleTracks: subtitleTracks ?? this.subtitleTracks,
      );
}

/// Profilo buffer: più buffer = più stabilità, meno = meno latenza.
enum BufferProfile { lowLatency, balanced, stable }

/// Motore di riproduzione "antifragile".
///
/// Stabilità:
///  - riconnessione automatica con backoff esponenziale (0.5s → 8s, 6 tentativi)
///  - failover sui link alternativi dello stesso canale ordinati per affidabilità
///  - watchdog: se il tempo non avanza per N secondi, riavvia lo stream
///  - memoria dei risultati per URL → i link buoni vengono provati per primi
///
/// Velocità:
///  - un solo Player libmpv riutilizzato (zero cold-start a ogni zapping)
///  - cache/prefetch impostati per profilo; decodifica HW (mediacodec / videotoolbox)
///  - cambio canale = open() sullo stesso player, ~300-600 ms su rete decente
class StreamEngine {
  StreamEngine(this._db, {BufferProfile profile = BufferProfile.balanced})
      : _profile = profile {
    _player = Player(
      configuration: const PlayerConfiguration(
        bufferSize: 64 * 1024 * 1024,
        title: 'Kairos Nova',
        logLevel: MPVLogLevel.warn,
      ),
    );
    _applyProfile();
    _wire();
  }

  final KairosDb _db;
  BufferProfile _profile;
  late final Player _player;
  Player get player => _player;

  final _status = ValueNotifier<EngineStatus>(
      const EngineStatus(state: EngineState.idle));
  ValueListenable<EngineStatus> get status => _status;

  Channel? _current;
  List<Channel> _alternatives = const [];
  int _altIndex = -1;
  int _attempt = 0;
  int _reconnects = 0;
  Timer? _retryTimer;
  Timer? _watchdog;
  Timer? _healthTimer;
  Duration _lastPos = Duration.zero;
  DateTime? _lastProgress;
  DateTime? _openedAt;
  bool _disposed = false;
  int _generation = 0;

  final _subs = <StreamSubscription>[];

  // ------------------------------------------------------------- Pubblico

  Future<void> play(Channel c, {Duration? startAt}) async {
    _generation++;
    final gen = _generation;
    _cancelTimers();
    _current = c;
    _attempt = 0;
    _reconnects = 0;
    _altIndex = -1;
    _alternatives = _rankAlternatives(c);
    _emit(EngineStatus(state: EngineState.connecting, channel: c));
    await _open(c, gen, startAt: startAt);
  }

  Future<void> stop() async {
    _generation++;
    _cancelTimers();
    _current = null;
    await _player.stop();
    _emit(const EngineStatus(state: EngineState.idle));
  }

  Future<void> togglePause() async {
    await _player.playOrPause();
  }

  Future<void> seek(Duration d) => _player.seek(d);

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
    final next = _pickAlternative();
    if (next == null) {
      _emit(_status.value.copyWith(message: 'Nessuna sorgente alternativa'));
      return;
    }
    _emit(_status.value.copyWith(
        state: EngineState.reconnecting, message: 'Sorgente ${_altIndex + 2}'));
    await _open(next, gen);
  }

  void setProfile(BufferProfile p) {
    _profile = p;
    _applyProfile();
  }

  Future<void> dispose() async {
    _disposed = true;
    _cancelTimers();
    for (final s in _subs) {
      await s.cancel();
    }
    await _player.dispose();
    _status.dispose();
  }

  // ------------------------------------------------------------- Interno

  void _applyProfile() {
    final native = _player.platform;
    if (native is! NativePlayer) return;
    final (secs, readahead) = switch (_profile) {
      BufferProfile.lowLatency => (4, 'no'),
      BufferProfile.balanced => (12, 'yes'),
      BufferProfile.stable => (30, 'yes'),
    };
    native.setProperty('cache', 'yes');
    native.setProperty('cache-secs', '$secs');
    native.setProperty('demuxer-readahead-secs', '$secs');
    native.setProperty('demuxer-max-bytes', '${64 * 1024 * 1024}');
    native.setProperty('demuxer-max-back-bytes', '${16 * 1024 * 1024}');
    native.setProperty('cache-pause', readahead);
    native.setProperty('cache-pause-initial', 'yes');
    native.setProperty('cache-pause-wait', '1');
    native.setProperty('network-timeout', '15');
    native.setProperty('stream-lavf-o', 'reconnect=1,reconnect_streamed=1,reconnect_delay_max=4,rw_timeout=15000000');
    native.setProperty('hwdec', 'auto-safe');
    native.setProperty('vd-lavc-dr', 'yes');
    native.setProperty('video-sync', 'audio');
    native.setProperty('hls-bitrate', 'max');
    native.setProperty('tls-verify', 'no');
    native.setProperty('user-agent', 'KairosNova/1.0');
  }

  Future<void> _open(Channel c, int gen, {Duration? startAt}) async {
    if (_disposed || gen != _generation) return;
    _openedAt = DateTime.now();
    _lastPos = Duration.zero;
    _lastProgress = DateTime.now();

    final native = _player.platform;
    if (native is NativePlayer) {
      final h = c.headers;
      if (h != null && h.isNotEmpty) {
        await native.setProperty(
            'http-header-fields', h.entries.map((e) => '${e.key}: ${e.value}').join(','));
        if (h['User-Agent'] != null) {
          await native.setProperty('user-agent', h['User-Agent']!);
        }
      } else {
        await native.setProperty('http-header-fields', '');
        await native.setProperty('user-agent', 'KairosNova/1.0');
      }
    }

    try {
      await _player.open(Media(c.url, start: startAt), play: true);
      _startWatchdog();
      _startHealth();
    } catch (e) {
      _onFailure('Apertura fallita: $e');
    }
  }

  void _wire() {
    final s = _player.stream;
    _subs.add(s.playing.listen((p) {
      if (p && _status.value.state != EngineState.playing) {
        final startMs = _openedAt == null
            ? 0
            : DateTime.now().difference(_openedAt!).inMilliseconds;
        final c = _current;
        if (c != null) {
          _db.recordStreamResult(_playingUrl ?? c.url, ok: true, startMs: startMs);
          _db.recordPlay(c);
        }
        _attempt = 0;
        _emit(_status.value.copyWith(state: EngineState.playing, message: null));
      }
    }));
    _subs.add(s.buffering.listen((b) {
      if (b && _status.value.state == EngineState.playing) {
        _emit(_status.value.copyWith(state: EngineState.buffering));
      } else if (!b && _status.value.state == EngineState.buffering) {
        _emit(_status.value.copyWith(state: EngineState.playing));
      }
    }));
    _subs.add(s.position.listen((p) {
      if (p != _lastPos) {
        _lastPos = p;
        _lastProgress = DateTime.now();
      }
      _emit(_status.value.copyWith(position: p));
    }));
    _subs.add(s.duration.listen((d) {
      _emit(_status.value.copyWith(
          duration: d, isLive: d == Duration.zero || d.inHours > 20));
    }));
    _subs.add(s.tracks.listen((t) {
      _emit(_status.value.copyWith(
          audioTracks: t.audio, subtitleTracks: t.subtitle));
    }));
    _subs.add(s.error.listen((e) {
      if (_current == null) return;
      _onFailure(e);
    }));
    _subs.add(s.completed.listen((done) {
      final st = _status.value;
      if (done && st.isLive && _current != null) {
        // Un live che "finisce" è una caduta del server: riconnetti.
        _onFailure('Stream interrotto dal server');
      }
    }));
  }

  String? get _playingUrl {
    final idx = _altIndex;
    if (idx < 0) return _current?.url;
    return idx < _alternatives.length ? _alternatives[idx].url : _current?.url;
  }

  void _startWatchdog() {
    _watchdog?.cancel();
    _watchdog = Timer.periodic(const Duration(seconds: 2), (_) {
      if (_current == null) return;
      final st = _status.value.state;
      final stalled = _lastProgress != null &&
          DateTime.now().difference(_lastProgress!).inSeconds > 12;
      final neverStarted = st == EngineState.connecting &&
          _openedAt != null &&
          DateTime.now().difference(_openedAt!).inSeconds > 18;
      if ((st == EngineState.playing || st == EngineState.buffering) && stalled) {
        _onFailure('Stream bloccato, riavvio…');
      } else if (neverStarted) {
        _onFailure('Il server non risponde');
      }
    });
  }

  void _startHealth() {
    _healthTimer?.cancel();
    _healthTimer = Timer.periodic(const Duration(seconds: 1), (_) async {
      final native = _player.platform;
      if (native is! NativePlayer || _current == null) return;
      try {
        final cache = await native.getProperty('demuxer-cache-duration');
        final br = await native.getProperty('video-bitrate');
        final w = await native.getProperty('width');
        final h = await native.getProperty('height');
        final fps = await native.getProperty('estimated-vf-fps');
        final drop = await native.getProperty('frame-drop-count');
        final codec = await native.getProperty('video-codec');
        _emit(_status.value.copyWith(
          health: StreamHealth(
            bufferSeconds: double.tryParse(cache) ?? 0,
            bitrateKbps: ((double.tryParse(br) ?? 0) / 1000).round(),
            width: int.tryParse(w) ?? 0,
            height: int.tryParse(h) ?? 0,
            fps: double.tryParse(fps) ?? 0,
            droppedFrames: int.tryParse(drop) ?? 0,
            reconnects: _reconnects,
            latencyMs: _openedAt == null
                ? 0
                : _status.value.state == EngineState.playing
                    ? _status.value.health.latencyMs
                    : DateTime.now().difference(_openedAt!).inMilliseconds,
            codec: codec.split(' ').first,
          ),
        ));
      } catch (_) {}
    });
  }

  void _onFailure(String reason) {
    final c = _current;
    if (c == null || _disposed) return;
    final gen = _generation;
    _db.recordStreamResult(_playingUrl ?? c.url, ok: false);
    _watchdog?.cancel();
    _retryTimer?.cancel();
    _attempt++;
    _reconnects++;

    // Dopo 2 tentativi sullo stesso link, prova un'alternativa.
    Channel target = _altIndex < 0 ? c : _alternatives[_altIndex];
    if (_attempt > 2) {
      final alt = _pickAlternative();
      if (alt != null) {
        target = alt;
        _attempt = 1;
      }
    }

    if (_attempt > 6 && _altIndex >= _alternatives.length - 1) {
      _emit(EngineStatus(
          state: EngineState.failed, channel: c, attempt: _attempt,
          message: 'Canale non disponibile al momento'));
      return;
    }

    final delayMs = (500 * (1 << (_attempt - 1).clamp(0, 4))).clamp(500, 8000);
    _emit(_status.value.copyWith(
      state: EngineState.reconnecting,
      attempt: _attempt,
      message: _altIndex >= 0
          ? 'Sorgente ${_altIndex + 2} · tentativo $_attempt'
          : '$reason · tentativo $_attempt',
    ));
    _retryTimer = Timer(Duration(milliseconds: delayMs), () {
      if (gen != _generation) return;
      _open(target, gen);
    });
  }

  Channel? _pickAlternative() {
    if (_altIndex + 1 >= _alternatives.length) return null;
    _altIndex++;
    return _alternatives[_altIndex];
  }

  List<Channel> _rankAlternatives(Channel c) {
    final alts = _db.alternatives(c, limit: 8);
    alts.sort((a, b) => _db.reliability(b.url).compareTo(_db.reliability(a.url)));
    return alts;
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
