import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../core/models/models.dart';
import '../../core/panel/panel_service.dart';
import '../../core/parental.dart';
import '../../core/player/stream_engine.dart';
import '../../core/providers.dart';
import '../../core/theme/kairos_theme.dart';
import '../../shared/widgets/widgets.dart';

final RegExp _digitRe = RegExp(r'\d');

class PlayerScreen extends ConsumerStatefulWidget {
  const PlayerScreen({super.key, required this.channelId});
  final int channelId;
  @override
  ConsumerState<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends ConsumerState<PlayerScreen> {
  late final StreamEngine _engine;
  late final VideoController _video;
  Channel? _channel;
  bool _showUi = true;
  bool _showList = false;
  bool _showInfo = false;
  Timer? _hideTimer;
  String _numberBuffer = '';
  Timer? _numberTimer;
  double? _gestureStart;
  double _gestureValue = 0;
  _Gesture _gesture = _Gesture.none;
  BoxFit _fit = BoxFit.contain;
  double _brightness = 1.0; // dimmer software (overlay)
  double _volume = 1.0;
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    final watching = ref.read(watchingProvider.notifier); // niente aggiornamenti in background durante la visione
    Future.microtask(() => watching.state++);
    _engine = ref.read(engineProvider);
    _video = _engine.video; // un solo VideoController per tutta la vita del motore (niente texture perse a ogni apertura)
    // si entra nel lettore: via dalla memoria le immagini decodificate che nessuna schermata mostra (quelle ancora
    // a vista restano), così il buffer video ha più spazio sui dispositivi con poca memoria
    PaintingBinding.instance.imageCache.clear();
    WakelockPlus.enable();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _load(widget.channelId);
    _scheduleHide();
  }

  void _load(int id, {bool resume = true}) {
    final db = ref.read(dbProvider);
    var c = db.channel(id);
    if (c == null) return;
    final local = ref.read(downloadManagerProvider).localPathFor(id);
    if (local != null) c = c.copyWith(url: local); // riproduzione offline
    // controllo genitori: canale o gruppo per adulti → prima il PIN (annullando si torna indietro)
    if (parentalLockedChannel(ref, c)) {
      final ch = c;
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) return;
        final ok = await parentalGate(context, ref, channel: ch);
        if (!mounted) return;
        if (ok) _load(id, resume: resume); else if (context.canPop()) context.pop();
      });
      return;
    }
    setState(() => _channel = c);
    Duration? start;
    if (resume && c.type != ChannelType.live) {
      final pos = db.resumePosition(id);
      if (pos > 30000) start = Duration(milliseconds: pos);
    }
    _engine.play(c, startAt: start);
  }

  void _zap({required bool next}) {
    final c = _channel;
    if (c == null) return;
    final n = ref.read(dbProvider).neighbour(c, next: next);
    if (n != null) {
      _load(n.id, resume: false);
      _flashUi();
    }
  }

  void _onDigit(String d) {
    _numberBuffer += d;
    _numberTimer?.cancel();
    setState(() {});
    _numberTimer = Timer(const Duration(milliseconds: 1500), () {
      final n = int.tryParse(_numberBuffer);
      final pl = ref.read(activePlaylistIdProvider);
      if (n != null && pl != null) {
        final c = ref.read(dbProvider).channelByNumber(pl, n);
        if (c != null) _load(c.id, resume: false);
      }
      setState(() => _numberBuffer = '');
    });
  }

  void _flashUi() {
    setState(() => _showUi = true);
    _scheduleHide();
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 4), () {
      if (mounted && !_showList && !_showInfo) setState(() => _showUi = false);
    });
  }

  void _toggleUi() {
    if (_showList || _showInfo) {
      setState(() { _showList = false; _showInfo = false; });
      _scheduleHide();
      return;
    }
    setState(() => _showUi = !_showUi);
    if (_showUi) _scheduleHide();
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _numberTimer?.cancel();
    final watching = ref.read(watchingProvider.notifier);
    Future.microtask(() => watching.state--);
    final st = _engine.status.value;
    if (_channel != null && !st.isLive && st.state != EngineState.idle) {
      try {
        ref.read(dbProvider).recordPlay(_channel!,
            positionMs: st.position.inMilliseconds, durationMs: st.duration.inMilliseconds);
      } catch (_) {
        // database occupato da un import: la posizione non si salva, ma il lettore si chiude comunque (sotto)
      }
      final pv = ref.read(playVersionProvider.notifier); // «Continua a guardare» aggiornato una volta, alla chiusura
      Future.microtask(() => pv.state++);
    }
    unawaited(_engine.stop());
    WakelockPlus.disable();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _focus.dispose();
    super.dispose();
  }

  KeyEventResult _onKey(FocusNode n, KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    if (k == LogicalKeyboardKey.arrowUp || k == LogicalKeyboardKey.channelUp || k == LogicalKeyboardKey.pageUp) {
      if (!_showList) { _zap(next: false); return KeyEventResult.handled; }
    }
    if (k == LogicalKeyboardKey.arrowDown || k == LogicalKeyboardKey.channelDown || k == LogicalKeyboardKey.pageDown) {
      if (!_showList) { _zap(next: true); return KeyEventResult.handled; }
    }
    if (k == LogicalKeyboardKey.arrowLeft && !_showList) {
      final st = _engine.status.value;
      if (!st.isLive) _engine.seek(st.position - const Duration(seconds: 10));
      _flashUi();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowRight && !_showList) {
      final st = _engine.status.value;
      if (!st.isLive) _engine.seek(st.position + const Duration(seconds: 30));
      _flashUi();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.select || k == LogicalKeyboardKey.enter || k == LogicalKeyboardKey.space ||
        k == LogicalKeyboardKey.mediaPlayPause) {
      if (!_showList) { _engine.togglePause(); _flashUi(); return KeyEventResult.handled; }
    }
    if (k == LogicalKeyboardKey.contextMenu || k == LogicalKeyboardKey.info || k == LogicalKeyboardKey.keyI) {
      setState(() { _showInfo = !_showInfo; _showUi = true; });
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.guide || k == LogicalKeyboardKey.keyL) {
      setState(() { _showList = !_showList; _showUi = true; });
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.goBack || k == LogicalKeyboardKey.escape) {
      if (_showList || _showInfo) { setState(() { _showList = false; _showInfo = false; }); return KeyEventResult.handled; }
      context.pop();
      return KeyEventResult.handled;
    }
    final label = k.keyLabel;
    if (label.length == 1 && _digitRe.hasMatch(label)) {
      _onDigit(label);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  // ------------------------------------------------------------ Gesture

  void _onVStart(DragStartDetails d) {
    final w = MediaQuery.sizeOf(context).width;
    _gesture = d.globalPosition.dx < w / 2 ? _Gesture.brightness : _Gesture.volume;
    _gestureStart = d.globalPosition.dy;
  }

  void _onVUpdate(DragUpdateDetails d) {
    if (_gestureStart == null) return;
    final h = MediaQuery.sizeOf(context).height;
    final delta = (_gestureStart! - d.globalPosition.dy) / (h * 0.6);
    if (_gesture == _Gesture.brightness) {
      _brightness = (_brightness + delta).clamp(0.15, 1.0);
      setState(() => _gestureValue = _brightness);
    } else {
      _volume = (_volume + delta).clamp(0.0, 1.0);
      _engine.setVolume(_volume * 100);
      setState(() => _gestureValue = _volume);
    }
    _gestureStart = d.globalPosition.dy;
  }

  void _onVEnd(DragEndDetails d) {
    // Swipe verticale veloce = zapping (come i telecomandi)
    if ((d.primaryVelocity ?? 0).abs() > 1400 && _gesture != _Gesture.none) {
      _zap(next: (d.primaryVelocity ?? 0) < 0);
    }
    setState(() => _gesture = _Gesture.none);
    _gestureStart = null;
  }

  // ------------------------------------------------------------ Build

  @override
  Widget build(BuildContext context) {
    final c = _channel;
    final settings = ref.watch(settingsProvider);
    // permesso «resInd» del pannello: risoluzione e FPS (riquadro della diretta, indicatore e diagnostica)
    final resInd = ref.watch(panelProvider.select((p) => p.perm('resInd')));
    final live = c != null && c.type == ChannelType.live;
    final topPad = MediaQuery.paddingOf(context).top;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Focus(
        focusNode: _focus,
        autofocus: true,
        onKeyEvent: _onKey,
        child: Stack(fit: StackFit.expand, children: [
          // Video: fuori dal ValueListenableBuilder, non si ricostruisce a ogni tick del motore
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _toggleUi,
            onDoubleTap: () { _engine.togglePause(); _flashUi(); },
            onVerticalDragStart: _onVStart,
            onVerticalDragUpdate: _onVUpdate,
            onVerticalDragEnd: _onVEnd,
            onHorizontalDragEnd: (d) {
              if (!_engine.status.value.isLive) return;
              if ((d.primaryVelocity ?? 0) < -500) setState(() => _showList = true);
            },
            child: Video(
              controller: _video,
              fit: _fit,
              controls: NoVideoControls,
              fill: Colors.black,
            ),
          ),

          // Dimmer software (luminosità)
          if (_brightness < 1)
            IgnorePointer(child: Container(color: Colors.black.withOpacity(1 - _brightness))),

          // Overlay che dipendono dallo stato del motore (posizione al massimo 4 volte al secondo)
          ValueListenableBuilder<EngineStatus>(
            valueListenable: _engine.status,
            builder: (context, st, _) => Stack(fit: StackFit.expand, children: [
              // Stato connessione
              if (st.state == EngineState.connecting ||
                  st.state == EngineState.buffering ||
                  st.state == EngineState.reconnecting)
                Center(child: _Spinner(st)),
              if (st.state == EngineState.failed) Center(child: _Failed(st, onRetry: () => _engine.play(c!), onAlt: _engine.nextSource)),
              // Fine di un contenuto on demand
              if (st.state == EngineState.ended && c != null)
                Center(child: _Ended(onReplay: () => _engine.play(c), onClose: () => context.pop())),

              // Gesture feedback
              if (_gesture != _Gesture.none)
                Center(
                  child: GlassPanel(
                    radius: 16,
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(_gesture == _Gesture.brightness ? Icons.brightness_6_rounded : Icons.volume_up_rounded, color: KairosColors.cyan),
                      const SizedBox(width: 12),
                      SizedBox(width: 140, child: ProgressBar(_gestureValue, height: 5)),
                    ]),
                  ),
                ),

              // Numero canale digitato
              if (_numberBuffer.isNotEmpty)
                Positioned(
                  top: 40, right: 40,
                  child: GlassPanel(glow: true, child: Text(_numberBuffer,
                      style: const TextStyle(fontSize: 40, fontWeight: FontWeight.w800, letterSpacing: 4))),
                ),

              // Overlay diagnostica
              if (resInd && (settings.showHealthOverlay || _showInfo))
                Positioned(top: 24, left: 24, child: _HealthBadge(st.health, st)),

              // UI principale
              AnimatedOpacity(
                opacity: _showUi ? 1 : 0,
                duration: const Duration(milliseconds: 220),
                child: IgnorePointer(
                  ignoring: !_showUi,
                  child: _Overlay(
                    channel: c,
                    status: st,
                    engine: _engine,
                    fit: _fit,
                    onFit: () => setState(() => _fit = _fit == BoxFit.contain ? BoxFit.cover : _fit == BoxFit.cover ? BoxFit.fill : BoxFit.contain),
                    onList: () => setState(() => _showList = !_showList),
                    onInfo: () => setState(() => _showInfo = !_showInfo),
                    onZap: _zap,
                    onInteract: _scheduleHide,
                  ),
                ),
              ),

              // Qualità · risoluzione · FPS dei canali in diretta, in alto a destra sotto la barra (non prende il focus)
              if (resInd && live)
                Positioned(
                  top: topPad + 64,
                  right: 20,
                  child: IgnorePointer(child: _ResBox(status: st, osd: _showUi, hidden: _numberBuffer.isNotEmpty)),
                ),
            ]),
          ),

          // Lista canali laterale (non dipende dallo stato del motore)
          if (_showList && c != null)
            Positioned(
              left: 0, top: 0, bottom: 0,
              child: _SideList(
                current: c,
                onPick: (ch) { _load(ch.id, resume: false); setState(() => _showList = false); _scheduleHide(); },
                onClose: () => setState(() => _showList = false),
              ).animate().slideX(begin: -1, end: 0, duration: 240.ms, curve: Curves.easeOutCubic),
            ),
        ]),
      ),
    );
  }
}

/// Fine di un film/episodio: «Riguarda» o «Chiudi» (nessun riavvio automatico).
class _Ended extends StatelessWidget {
  const _Ended({required this.onReplay, required this.onClose});
  final VoidCallback onReplay, onClose;
  @override
  Widget build(BuildContext context) => GlassPanel(
        radius: 18,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.check_circle_outline_rounded, color: KairosColors.lime, size: 40),
          const SizedBox(height: 10),
          const Text('Fine', style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 14),
          Row(mainAxisSize: MainAxisSize.min, children: [
            FilledButton.icon(autofocus: true, onPressed: onClose, icon: const Icon(Icons.arrow_back_rounded), label: const Text('Chiudi')),
            const SizedBox(width: 10),
            OutlinedButton.icon(onPressed: onReplay, icon: const Icon(Icons.replay_rounded), label: const Text('Riguarda')),
          ]),
        ]),
      );
}

enum _Gesture { none, brightness, volume }

class _Spinner extends StatelessWidget {
  const _Spinner(this.st);
  final EngineStatus st;
  @override
  Widget build(BuildContext context) => GlassPanel(
        radius: 18,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const SizedBox(width: 34, height: 34, child: CircularProgressIndicator(strokeWidth: 3, color: KairosColors.cyan)),
          const SizedBox(height: 12),
          Text(
            switch (st.state) {
              EngineState.connecting => 'Connessione…',
              EngineState.buffering => 'Buffering ${st.health.bufferSeconds.toStringAsFixed(0)}s',
              EngineState.reconnecting => st.message ?? 'Riconnessione…',
              _ => '',
            },
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ]),
      );
}

class _Failed extends StatelessWidget {
  const _Failed(this.st, {required this.onRetry, required this.onAlt});
  final EngineStatus st;
  final VoidCallback onRetry, onAlt;
  @override
  Widget build(BuildContext context) => GlassPanel(
        radius: 18,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.signal_wifi_bad_rounded, color: KairosColors.red, size: 40),
          const SizedBox(height: 10),
          Text(st.message ?? 'Errore', style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 14),
          Row(mainAxisSize: MainAxisSize.min, children: [
            FilledButton.icon(autofocus: true, onPressed: onRetry, icon: const Icon(Icons.refresh_rounded), label: const Text('Riprova')),
            const SizedBox(width: 10),
            OutlinedButton.icon(onPressed: onAlt, icon: const Icon(Icons.swap_horiz_rounded), label: const Text('Altra sorgente')),
          ]),
        ]),
      );
}

class _HealthBadge extends StatelessWidget {
  const _HealthBadge(this.h, this.st);
  final StreamHealth h;
  final EngineStatus st;
  @override
  Widget build(BuildContext context) {
    const s = TextStyle(fontSize: 11.5, fontFamily: 'monospace', color: KairosColors.textDim);
    return GlassPanel(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      radius: 10,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('${h.resolutionLabel} ${h.width}×${h.height} · ${h.fps.toStringAsFixed(0)} fps · ${h.codec}${h.hwdec.isEmpty ? '' : ' · ${h.hwdec}'}',
            style: s.copyWith(color: KairosColors.cyan)),
        Text('bitrate ${h.bitrateKbps} kbps · rete ${h.speedKbps} kbps · buffer ${h.bufferSeconds.toStringAsFixed(1)}s', style: s),
        Text('drop ${h.droppedFrames} · stalli ${h.stalls} · reconnect ${h.reconnects} · start ${h.latencyMs} ms', style: s),
        Text('linea ${h.line}${h.fmt.isEmpty ? '' : ' · ${h.fmt}'} · audio ${st.audioTracks.length} · sub ${st.subtitleTracks.length} · ${st.state.name}', style: s),
        if (h.message != null) Text(h.message!, style: s.copyWith(color: KairosColors.magenta)),
      ]),
    );
  }
}

class _Overlay extends ConsumerWidget {
  const _Overlay({
    required this.channel, required this.status, required this.engine, required this.fit,
    required this.onFit, required this.onList, required this.onInfo, required this.onZap, required this.onInteract,
  });
  final Channel? channel;
  final EngineStatus status;
  final StreamEngine engine;
  final BoxFit fit;
  final VoidCallback onFit, onList, onInfo, onInteract;
  final void Function({required bool next}) onZap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = channel;
    if (c == null) return const SizedBox();
    final nn = ref.watch(nowNextProvider(c.tvgId));
    final now = DateTime.now();
    final pad = MediaQuery.paddingOf(context);
    final resInd = ref.watch(panelProvider.select((p) => p.perm('resInd')));

    return Column(children: [
      // Top bar
      Container(
        padding: EdgeInsets.fromLTRB(12, pad.top + 8, 12, 24),
        decoration: const BoxDecoration(
          gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter,
              colors: [Color(0xCC000000), Colors.transparent]),
        ),
        child: Row(children: [
          IconButton(onPressed: () => context.pop(), icon: const Icon(Icons.arrow_back_rounded)),
          ChannelLogo(c, size: 40),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(c.name, maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 17)),
              Text('${c.groupName}${c.number != null ? ' · CH ${c.number}' : ''}',
                  style: const TextStyle(color: KairosColors.textDim, fontSize: 12)),
            ]),
          ),
          if (resInd) _Badge(status.health.resolutionLabel, status.state == EngineState.playing ? KairosColors.lime : KairosColors.textDim),
          if (status.isLive) const _Badge('LIVE', KairosColors.red),
          IconButton(onPressed: () { ref.read(actionsProvider).toggleFavorite(c); onInteract(); },
              icon: Icon(c.isFavorite ? Icons.favorite : Icons.favorite_border, color: KairosColors.magenta)),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert_rounded),
            color: KairosColors.surfaceHi,
            onSelected: (v) {
              switch (v) {
                case 'source': engine.nextSource();
                case 'info': onInfo();
                case 'fit': onFit();
                case 'multi':
                  // il lettore singolo si ferma (niente audio doppio né banda ×5): questa schermata viene sostituita
                  unawaited(engine.pause());
                  context.pushReplacement('/multiview?add=${c.id}');
                case 'audio': _trackSheet(context, status.audioTracks, (t) => engine.setAudioTrack(t));
                case 'sub': _trackSheet(context, status.subtitleTracks, (t) => engine.setSubtitleTrack(t));
                case 'speed': _speedSheet(context, engine);
                case 'download':
                  ref.read(downloadManagerProvider).enqueue(c).then((item) {
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                        content: Text(item == null ? 'Già in download o scaricato' : 'Download avviato: ${c.name}')));
                  });
              }
              onInteract();
            },
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'source', child: ListTile(leading: Icon(Icons.swap_horiz_rounded), title: Text('Cambia sorgente'))),
              PopupMenuItem(value: 'audio', child: ListTile(leading: const Icon(Icons.audiotrack_rounded), title: Text('Audio (${status.audioTracks.length})'))),
              PopupMenuItem(value: 'sub', child: ListTile(leading: const Icon(Icons.subtitles_rounded), title: Text('Sottotitoli (${status.subtitleTracks.length})'))),
              const PopupMenuItem(value: 'fit', child: ListTile(leading: Icon(Icons.aspect_ratio_rounded), title: Text('Formato schermo'))),
              if (!status.isLive) const PopupMenuItem(value: 'speed', child: ListTile(leading: Icon(Icons.speed_rounded), title: Text('Velocità'))),
              if (c.type == ChannelType.movie || c.type == ChannelType.series)
                const PopupMenuItem(value: 'download', child: ListTile(leading: Icon(Icons.download_rounded), title: Text('Scarica offline'))),
              const PopupMenuItem(value: 'multi', child: ListTile(leading: Icon(Icons.grid_view_rounded), title: Text('Multiview'))),
              if (resInd) const PopupMenuItem(value: 'info', child: ListTile(leading: Icon(Icons.analytics_outlined), title: Text('Diagnostica'))),
            ],
          ),
        ]),
      ),
      const Spacer(),
      // Bottom
      Container(
        padding: EdgeInsets.fromLTRB(20, 30, 20, pad.bottom + 14),
        decoration: const BoxDecoration(
          gradient: LinearGradient(begin: Alignment.bottomCenter, end: Alignment.topCenter,
              colors: [Color(0xE6000000), Colors.transparent]),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          if (nn.now != null) ...[
            Row(children: [
              Expanded(child: Text(nn.now!.title, maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700))),
              Text('${DateFormat.Hm().format(nn.now!.start)} – ${DateFormat.Hm().format(nn.now!.stop)}',
                  style: const TextStyle(color: KairosColors.textDim)),
            ]),
            const SizedBox(height: 6),
            ProgressBar(nn.now!.progressAt(now), height: 4),
            if (nn.next != null) Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text('A seguire: ${nn.next!.title} · ${DateFormat.Hm().format(nn.next!.start)}',
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: KairosColors.textDim, fontSize: 13)),
            ),
          ] else if (!status.isLive) ...[
            Row(children: [
              Text(_fmt(status.position), style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()])),
              Expanded(
                child: Slider(
                  value: status.duration.inMilliseconds == 0 ? 0 : (status.position.inMilliseconds / status.duration.inMilliseconds).clamp(0, 1),
                  activeColor: KairosColors.cyan,
                  onChanged: (v) => engine.seek(status.duration * v),
                ),
              ),
              Text(_fmt(status.duration), style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()])),
            ]),
          ],
          const SizedBox(height: 10),
          Row(children: [
            _Ctl(Icons.list_rounded, 'Canali', onList),
            _Ctl(Icons.skip_previous_rounded, 'Prec', () => onZap(next: false)),
            StreamBuilder<bool>(
              stream: engine.player.stream.playing,
              builder: (_, s) => _Ctl(
                (s.data ?? true) ? Icons.pause_rounded : Icons.play_arrow_rounded, '', engine.togglePause, big: true, autofocus: true),
            ),
            _Ctl(Icons.skip_next_rounded, 'Succ', () => onZap(next: true)),
            _Ctl(Icons.calendar_view_day_rounded, 'Guida', () { context.pop(); context.go('/guide'); }),
          ]),
        ]),
      ),
    ]);
  }

  static String _fmt(Duration d) {
    final h = d.inHours, m = d.inMinutes % 60, s = d.inSeconds % 60;
    String two(int n) => n.toString().padLeft(2, '0');
    return h > 0 ? '$h:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
  }

  void _trackSheet<T>(BuildContext context, List<T> tracks, void Function(T) onPick) {
    showModalBottomSheet(
      context: context,
      backgroundColor: KairosColors.bgElevated,
      builder: (ctx) => ListView(
        shrinkWrap: true,
        children: [
          for (final t in tracks)
            ListTile(
              title: Text(_trackLabel(t)),
              onTap: () { onPick(t); Navigator.pop(ctx); },
            ),
          if (tracks.isEmpty) const ListTile(title: Text('Nessuna traccia disponibile')),
        ],
      ),
    );
  }

  static String _trackLabel(dynamic t) {
    if (t is AudioTrack) return '${t.title ?? t.language ?? t.id}${t.language != null ? ' (${t.language})' : ''}';
    if (t is SubtitleTrack) return t.id == 'no' ? 'Disattivati' : '${t.title ?? t.language ?? t.id}';
    return '$t';
  }

  void _speedSheet(BuildContext context, StreamEngine engine) {
    showModalBottomSheet(
      context: context,
      backgroundColor: KairosColors.bgElevated,
      builder: (ctx) => Wrap(children: [
        for (final r in [0.5, 0.75, 1.0, 1.25, 1.5, 2.0])
          ListTile(title: Text('${r}x'), onTap: () { engine.setRate(r); Navigator.pop(ctx); }),
      ]),
    );
  }
}

class _Ctl extends StatelessWidget {
  const _Ctl(this.icon, this.label, this.onTap, {this.big = false, this.autofocus = false});
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool big, autofocus;
  @override
  Widget build(BuildContext context) => Expanded(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          IconButton.filledTonal(
            autofocus: autofocus,
            onPressed: onTap,
            iconSize: big ? 38 : 26,
            style: IconButton.styleFrom(
              backgroundColor: big ? KairosColors.cyan : Colors.white.withOpacity(0.1),
              foregroundColor: big ? Colors.black : Colors.white,
            ),
            icon: Icon(icon),
          ),
          if (label.isNotEmpty) Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(label, style: const TextStyle(fontSize: 11, color: KairosColors.textDim)),
          ),
        ]),
      );
}

/// Riquadro «FHD · 1080p · 50 fps» per i canali in diretta: ~6 s dopo il primo fotogramma, ~4 s a ogni cambio di
/// risoluzione (qualità adattiva) e sempre mentre è aperta la barra informazioni. FPS omessi se il motore non li dà.
class _ResBox extends StatefulWidget {
  const _ResBox({required this.status, required this.osd, required this.hidden});
  final EngineStatus status;
  final bool osd;
  final bool hidden;

  @override
  State<_ResBox> createState() => _ResBoxState();
}

class _ResBoxState extends State<_ResBox> {
  Timer? _timer;
  bool _timed = false;
  bool _started = false;
  int _height = 0;
  int? _channelId;

  @override
  void initState() {
    super.initState();
    _check();
  }

  @override
  void didUpdateWidget(covariant _ResBox old) {
    super.didUpdateWidget(old);
    _check();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  /// Nuovo canale: si riparte; primo fotogramma: 6 s; risoluzione cambiata: 4 s.
  void _check() {
    final st = widget.status;
    final id = st.channel?.id;
    if (id != _channelId) {
      _channelId = id;
      _started = false;
      _height = 0;
      _show(null);
    }
    final h = st.health.height;
    if (h <= 0) return;
    if (!_started) {
      if (st.state != EngineState.playing) return;
      _started = true;
      _height = h;
      _show(const Duration(seconds: 6));
    } else if (h != _height) {
      _height = h;
      _show(const Duration(seconds: 4));
    }
  }

  void _show(Duration? d) {
    _timer?.cancel();
    _timer = null;
    _timed = d != null;
    if (d != null) {
      _timer = Timer(d, () {
        if (mounted) setState(() => _timed = false);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final st = widget.status;
    final h = st.health.height;
    final off = st.state == EngineState.failed || st.state == EngineState.ended || st.state == EngineState.idle;
    if (widget.hidden || off || !_started || h <= 0 || !(widget.osd || _timed)) return const SizedBox.shrink();
    final q = h >= 2000 ? '4K' : (h >= 1000 ? 'FHD' : (h >= 700 ? 'HD' : 'SD'));
    final fps = st.health.fps;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(color: const Color(0xB3000000), borderRadius: BorderRadius.circular(6)),
      child: Text(fps > 0 ? '$q · ${h}p · ${fps.round()} fps' : '$q · ${h}p',
          style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w700)),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge(this.text, this.color);
  final String text;
  final Color color;
  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(right: 6),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: color.withOpacity(0.7)),
        ),
        child: Text(text, style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w800, color: color, letterSpacing: 1)),
      );
}

/// Lista canali sovrapposta al video: stesso gruppo, virtualizzata.
class _SideList extends ConsumerWidget {
  const _SideList({required this.current, required this.onPick, required this.onClose});
  final Channel current;
  final ValueChanged<Channel> onPick;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final paged = ref.watch(pagedChannelsProvider(
        ChannelQuery(type: current.type, group: current.groupName, playlistId: current.playlistId)));
    final w = (MediaQuery.sizeOf(context).width * 0.42).clamp(280.0, 420.0);
    return SizedBox(
      width: w,
      child: GlassPanel(
        radius: 0,
        opacity: 0.85,
        padding: EdgeInsets.zero,
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 40, 8, 6),
            child: Row(children: [
              Expanded(child: Text(current.groupName, maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleMedium)),
              Text('${paged.total}', style: const TextStyle(color: KairosColors.textMute)),
              IconButton(onPressed: onClose, icon: const Icon(Icons.close_rounded)),
            ]),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: paged.total,
              itemExtent: 64,
              itemBuilder: (_, i) {
                final c = paged.at(i);
                if (c == null) return const SizedBox();
                final on = c.id == current.id;
                return ListTile(
                  autofocus: on,
                  selected: on,
                  selectedTileColor: KairosColors.cyan.withOpacity(0.12),
                  leading: ChannelLogo(c, size: 40),
                  title: Text(c.name, maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontWeight: on ? FontWeight.w700 : FontWeight.w500, fontSize: 14)),
                  subtitle: Consumer(builder: (_, r, __) {
                    final nn = r.watch(nowNextProvider(c.tvgId));
                    return nn.now == null ? const SizedBox() : Text(nn.now!.title, maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 11.5, color: KairosColors.textDim));
                  }),
                  onTap: () => onPick(c),
                );
              },
            ),
          ),
        ]),
      ),
    );
  }
}
