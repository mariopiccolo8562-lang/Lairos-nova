import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/panel/panel_service.dart';
import '../../core/parental.dart';
import '../../core/providers.dart';
import '../../core/theme/kairos_theme.dart';
import '../../core/update/app_updater.dart';
import '../settings/update_dialog.dart';

class _Dest {
  const _Dest(this.path, this.icon, this.selectedIcon, this.label);
  final String path;
  final IconData icon;
  final IconData selectedIcon;
  final String label;
}

const _dests = [
  _Dest('/', Icons.home_outlined, Icons.home_rounded, 'Home'),
  _Dest('/live', Icons.live_tv_outlined, Icons.live_tv_rounded, 'Live'),
  _Dest('/movies', Icons.movie_outlined, Icons.movie_rounded, 'Film'),
  _Dest('/series', Icons.video_library_outlined, Icons.video_library_rounded, 'Serie'),
  _Dest('/guide', Icons.calendar_view_day_outlined, Icons.calendar_view_day_rounded, 'Guida'),
  _Dest('/search', Icons.search_rounded, Icons.search_rounded, 'Cerca'),
  _Dest('/downloads', Icons.download_outlined, Icons.download_rounded, 'Download'),
  _Dest('/settings', Icons.tune_rounded, Icons.tune_rounded, 'Impostazioni'),
];

/// Shell adattiva: rail laterale (TV, tablet, landscape) o bottom bar (telefono).
/// Avvia anche il controllo degli aggiornamenti e mostra la proposta «Installa ora» quando è il momento.
class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key, required this.child});
  final Widget child;

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final u = ref.read(appUpdaterProvider);
      u.offer.addListener(_onOffer);
      final panel = ref.read(panelProvider);
      panel.uiCommand.addListener(_onPanelCommand);
      await u.start();
      final info = await NovaNative.deviceInfo();
      await panel.start(version: u.currentVersion, model: (info['model'] ?? '').toString());
      // controllo genitori: al primo avvio si chiede di scegliere il PIN (quello iniziale è 0000)
      await Future<void>.delayed(const Duration(milliseconds: 1800));
      if (mounted) await maybeAskParentalPin(context, ref);
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    ref.read(appUpdaterProvider).offer.removeListener(_onOffer);
    ref.read(panelProvider).uiCommand.removeListener(_onPanelCommand);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      ref.read(appUpdaterProvider).onForeground();
      ref.read(panelProvider).onForeground();
    }
  }

  /// Comandi del fornitore che toccano l'interfaccia.
  void _onPanelCommand() {
    final cmd = ref.read(panelProvider).uiCommand.value;
    if (cmd == null || !mounted) return;
    final kind = cmd.kind.split(':').first;
    switch (kind) {
      case 'reload':
        ref.read(appGenerationProvider.notifier).state++;
      case 'settings':
        context.go('/settings');
      case 'exit':
        exitApp();
      case 'pin':
        // il fornitore ha riportato il PIN a 0000: si chiede subito di sceglierne uno nuovo
        maybeAskParentalPin(context, ref, force: true);
      case 'relink':
        // scollegata dal fornitore: se non restano liste proprie si torna alla schermata iniziale
        context.go(ref.read(dbProvider).playlists().isEmpty ? '/import?first=1' : '/');
    }
  }

  void _onOffer() {
    final u = ref.read(appUpdaterProvider);
    if (u.offer.value == null || !mounted) return;
    u.offer.value = null;
    showUpdateDialog(context, u);
  }

  int _index(BuildContext context) {
    final loc = GoRouterState.of(context).uri.path;
    final i = _dests.indexWhere((d) => d.path != '/' && loc.startsWith(d.path));
    return i < 0 ? 0 : i;
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 760;
    final idx = _index(context);
    final child = widget.child;

    return Scaffold(
      body: Stack(children: [
        const _AmbientBackground(),
        if (wide)
          Row(children: [
            _Rail(index: idx),
            Expanded(child: child),
          ])
        else
          child,
      ]),
      bottomNavigationBar: wide
          ? null
          : ClipRect(
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                child: NavigationBar(
                  height: 66,
                  backgroundColor: KairosColors.bg.withOpacity(0.75),
                  indicatorColor: KairosColors.cyan.withOpacity(0.18),
                  selectedIndex: idx,
                  labelBehavior: NavigationDestinationLabelBehavior.alwaysHide,
                  onDestinationSelected: (i) => context.go(_dests[i].path),
                  destinations: [
                    for (final d in _dests)
                      NavigationDestination(
                        icon: Icon(d.icon, color: KairosColors.textDim),
                        selectedIcon: Icon(d.selectedIcon, color: KairosColors.cyan),
                        label: d.label,
                      ),
                  ],
                ),
              ),
            ),
    );
  }
}

class _Rail extends StatelessWidget {
  const _Rail({required this.index});
  final int index;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 92,
      padding: const EdgeInsets.symmetric(vertical: 24),
      decoration: const BoxDecoration(
        border: Border(right: BorderSide(color: KairosColors.line)),
      ),
      child: Column(children: [
        const PlasmaText('K',
            style: TextStyle(fontSize: 34, fontWeight: FontWeight.w900, letterSpacing: -2)),
        const SizedBox(height: 28),
        for (var i = 0; i < _dests.length; i++)
          _RailItem(dest: _dests[i], selected: i == index, autofocus: i == index),
      ]),
    );
  }
}

class _RailItem extends StatefulWidget {
  const _RailItem({required this.dest, required this.selected, this.autofocus = false});
  final _Dest dest;
  final bool selected;
  final bool autofocus;

  @override
  State<_RailItem> createState() => _RailItemState();
}

class _RailItemState extends State<_RailItem> {
  bool _focus = false;

  @override
  Widget build(BuildContext context) {
    final on = widget.selected || _focus;
    return FocusableActionDetector(
      autofocus: widget.autofocus,
      onShowFocusHighlight: (f) => setState(() => _focus = f),
      onShowHoverHighlight: (f) => setState(() => _focus = f),
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) {
          context.go(widget.dest.path);
          return null;
        }),
      },
      child: GestureDetector(
        onTap: () => context.go(widget.dest.path),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          margin: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            color: on ? KairosColors.cyan.withOpacity(0.14) : Colors.transparent,
            border: Border.all(
                color: _focus ? KairosColors.cyan.withOpacity(0.7) : Colors.transparent),
          ),
          child: Column(children: [
            Icon(widget.selected ? widget.dest.selectedIcon : widget.dest.icon,
                color: on ? KairosColors.cyan : KairosColors.textDim, size: 26),
            const SizedBox(height: 4),
            Text(widget.dest.label,
                style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w700,
                    color: on ? KairosColors.cyan : KairosColors.textMute)),
          ]),
        ),
      ),
    );
  }
}

/// Sfondo con due aloni colorati che respirano lentamente.
class _AmbientBackground extends StatefulWidget {
  const _AmbientBackground();
  @override
  State<_AmbientBackground> createState() => _AmbientBackgroundState();
}

class _AmbientBackgroundState extends State<_AmbientBackground>
    with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(seconds: 14))
    ..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (_, __) => CustomPaint(
        size: Size.infinite,
        painter: _AmbientPainter(_c.value),
      ),
    );
  }
}

class _AmbientPainter extends CustomPainter {
  _AmbientPainter(this.t);
  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = KairosColors.bg);
    void glow(Offset c, double r, Color color) {
      canvas.drawCircle(
        c, r,
        Paint()
          ..shader = RadialGradient(colors: [color.withOpacity(0.22), color.withOpacity(0)])
              .createShader(Rect.fromCircle(center: c, radius: r)),
      );
    }
    glow(Offset(size.width * (0.15 + 0.1 * t), size.height * 0.1), size.width * 0.55, KairosColors.violet);
    glow(Offset(size.width * (0.9 - 0.1 * t), size.height * (0.8 - 0.1 * t)), size.width * 0.5, KairosColors.cyan);
  }

  @override
  bool shouldRepaint(_AmbientPainter old) => old.t != t;
}
