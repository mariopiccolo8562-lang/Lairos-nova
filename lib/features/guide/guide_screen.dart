import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/models/models.dart';
import '../../core/providers.dart';
import '../../core/theme/kairos_theme.dart';
import '../../shared/widgets/widgets.dart';

/// Griglia EPG stile Sky/NOW: timeline orizzontale, canali verticali,
/// linea "adesso", scroll sincronizzato. Carica solo i canali visibili.
class GuideScreen extends ConsumerStatefulWidget {
  const GuideScreen({super.key});
  @override
  ConsumerState<GuideScreen> createState() => _GuideScreenState();
}

class _GuideScreenState extends ConsumerState<GuideScreen> {
  static const pxPerMinute = 6.0;
  static const rowH = 76.0;
  static const chanW = 150.0;

  final _hCtrl = ScrollController();
  final _vCtrl = ScrollController();
  late DateTime _from;
  String? _group;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _from = DateTime(now.year, now.month, now.day, now.hour).subtract(const Duration(hours: 1));
    WidgetsBinding.instance.addPostFrameCallback((_) => _jumpToNow(animate: false));
  }

  void _jumpToNow({bool animate = true}) {
    final x = (DateTime.now().difference(_from).inMinutes * pxPerMinute - 80).clamp(0.0, double.infinity);
    animate
        ? _hCtrl.animateTo(x, duration: const Duration(milliseconds: 400), curve: Curves.easeOutCubic)
        : _hCtrl.jumpTo(x);
  }

  @override
  void dispose() {
    _hCtrl.dispose();
    _vCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final db = ref.watch(dbProvider);
    ref.watch(epgTickProvider);
    final pl = ref.watch(activePlaylistIdProvider);
    final groups = ref.watch(groupsProvider(ChannelType.live));
    final hoursSpan = 30;
    final to = _from.add(Duration(hours: hoursSpan));
    final gridW = hoursSpan * 60 * pxPerMinute;

    final paged = ref.watch(pagedChannelsProvider(
        ChannelQuery(type: ChannelType.live, group: _group, playlistId: pl)));

    if (paged.total == 0) {
      return const EmptyState(icon: Icons.calendar_view_day_outlined, title: 'Nessun canale live');
    }
    final epgCount = (db.get('epg_updated') != null);

    return SafeArea(
      bottom: false,
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 12, 6),
          child: Row(children: [
            Text('Guida TV', style: Theme.of(context).textTheme.headlineMedium),
            const SizedBox(width: 14),
            Expanded(
              child: SizedBox(
                height: 36,
                child: ListView(scrollDirection: Axis.horizontal, children: [
                  _chip('Tutti', _group == null, () => setState(() => _group = null)),
                  for (final g in groups.take(60))
                    _chip(g.name, _group == g.name, () => setState(() => _group = g.name)),
                ]),
              ),
            ),
            IconButton(onPressed: _jumpToNow, icon: const Icon(Icons.my_location_rounded), tooltip: 'Adesso'),
          ]),
        ),
        if (!epgCount)
          Container(
            margin: const EdgeInsets.fromLTRB(20, 4, 20, 8),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
                color: KairosColors.amber.withOpacity(0.12),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: KairosColors.amber.withOpacity(0.4))),
            child: Row(children: [
              const Icon(Icons.info_outline, color: KairosColors.amber, size: 18),
              const SizedBox(width: 10),
              const Expanded(child: Text('Nessuna guida caricata. Aggiungi un URL EPG (XMLTV) nelle impostazioni.')),
              TextButton(onPressed: () => context.go('/settings'), child: const Text('Imposta')),
            ]),
          ),
        // Timeline header
        Row(children: [
          const SizedBox(width: chanW),
          Expanded(
            child: SingleChildScrollView(
              controller: _hCtrl,
              scrollDirection: Axis.horizontal,
              physics: const NeverScrollableScrollPhysics(),
              child: SizedBox(
                width: gridW,
                height: 28,
                child: Stack(children: [
                  for (var h = 0; h < hoursSpan * 2; h++)
                    Positioned(
                      left: h * 30 * pxPerMinute,
                      top: 6,
                      child: Text(DateFormat.Hm().format(_from.add(Duration(minutes: h * 30))),
                          style: Theme.of(context).textTheme.labelSmall),
                    ),
                ]),
              ),
            ),
          ),
        ]),
        const Divider(height: 1),
        Expanded(
          child: _SyncedGrid(
            hCtrl: _hCtrl,
            vCtrl: _vCtrl,
            paged: paged,
            from: _from,
            to: to,
            gridW: gridW,
            rowH: rowH,
            chanW: chanW,
            pxPerMinute: pxPerMinute,
          ),
        ),
      ]),
    );
  }

  Widget _chip(String label, bool on, VoidCallback onTap) => Padding(
        padding: const EdgeInsets.only(right: 8),
        child: ChoiceChip(
          label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
          selected: on,
          onSelected: (_) => onTap(),
          selectedColor: KairosColors.cyan.withOpacity(0.2),
          backgroundColor: KairosColors.surface,
          side: BorderSide(color: on ? KairosColors.cyan : KairosColors.line),
        ),
      );
}

class _SyncedGrid extends ConsumerStatefulWidget {
  const _SyncedGrid({
    required this.hCtrl, required this.vCtrl, required this.paged,
    required this.from, required this.to, required this.gridW,
    required this.rowH, required this.chanW, required this.pxPerMinute,
  });
  final ScrollController hCtrl, vCtrl;
  final PagedChannels paged;
  final DateTime from, to;
  final double gridW, rowH, chanW, pxPerMinute;

  @override
  ConsumerState<_SyncedGrid> createState() => _SyncedGridState();
}

class _SyncedGridState extends ConsumerState<_SyncedGrid> {
  final _cache = <String, List<EpgProgram>>{};
  final _loaded = <int>{};

  void _ensurePrograms(int firstIndex, int lastIndex) {
    final page = firstIndex ~/ 40;
    if (_loaded.contains(page)) return;
    final ids = <String>[];
    for (var i = page * 40; i < (page + 1) * 40 && i < widget.paged.total; i++) {
      final c = widget.paged.at(i);
      if (c?.tvgId != null) ids.add(c!.tvgId!);
    }
    if (ids.isEmpty) return;
    _loaded.add(page);
    final m = ref.read(dbProvider).programsFor(ids, widget.from, widget.to);
    _cache.addAll(m);
    WidgetsBinding.instance.addPostFrameCallback((_) => mounted ? setState(() {}) : null);
  }

  @override
  Widget build(BuildContext context) {
    final nowX = DateTime.now().difference(widget.from).inMinutes * widget.pxPerMinute;
    return Listener(
      // Lo scroll orizzontale della griglia trascina anche l'header
      child: NotificationListener<ScrollNotification>(
        onNotification: (n) {
          if (n.metrics.axis == Axis.horizontal && n.depth == 1) {
            widget.hCtrl.jumpTo(n.metrics.pixels);
          }
          return false;
        },
        child: ListView.builder(
          controller: widget.vCtrl,
          itemCount: widget.paged.total,
          itemExtent: widget.rowH,
          cacheExtent: 300,
          itemBuilder: (_, i) {
            _ensurePrograms(i, i);
            final c = widget.paged.at(i);
            if (c == null) return const SizedBox();
            final progs = _cache[c.tvgId] ?? const [];
            return _Row(
              channel: c,
              programs: progs,
              from: widget.from,
              gridW: widget.gridW,
              chanW: widget.chanW,
              pxPerMinute: widget.pxPerMinute,
              nowX: nowX,
              hOffset: widget.hCtrl.hasClients ? widget.hCtrl.offset : 0,
              first: i == 0,
            );
          },
        ),
      ),
    );
  }
}

/// Riga EPG: canale fisso a sinistra, programmi che scorrono orizzontalmente.
/// Tutte le righe condividono lo stesso offset leggendolo dall'header.
class _Row extends StatelessWidget {
  const _Row({
    required this.channel, required this.programs, required this.from,
    required this.gridW, required this.chanW, required this.pxPerMinute,
    required this.nowX, required this.hOffset, required this.first,
  });
  final Channel channel;
  final List<EpgProgram> programs;
  final DateTime from;
  final double gridW, chanW, pxPerMinute, nowX, hOffset;
  final bool first;

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      SizedBox(
        width: chanW,
        child: InkWell(
          onTap: () => context.push('/play/${channel.id}'),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Row(children: [
              ChannelLogo(channel, size: 40),
              const SizedBox(width: 8),
              Expanded(
                  child: Text(channel.name,
                      maxLines: 2, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600))),
            ]),
          ),
        ),
      ),
      Expanded(
        child: _HScroll(
          offset: hOffset,
          child: SizedBox(
            width: gridW,
            child: Stack(children: [
              Positioned(left: 0, right: 0, bottom: 0, child: Container(height: 1, color: KairosColors.line)),
              for (final p in programs)
                Positioned(
                  left: (p.start.difference(from).inMinutes * pxPerMinute).clamp(0, gridW),
                  width: ((p.stop.difference(p.start).inMinutes) * pxPerMinute - 3).clamp(20, gridW),
                  top: 6, bottom: 6,
                  child: _ProgramCell(p, channel: channel),
                ),
              if (programs.isEmpty)
                const Positioned(
                    left: 12, top: 0, bottom: 0,
                    child: Center(child: Text('Nessuna informazione', style: TextStyle(color: KairosColors.textMute, fontSize: 12)))),
              Positioned(left: nowX, top: 0, bottom: 0, child: Container(width: 2, color: KairosColors.red)),
            ]),
          ),
        ),
      ),
    ]);
  }
}

/// Scroll orizzontale condiviso: ogni riga è uno Scrollable con il proprio
/// controller ma inizializzato all'offset comune; le notifiche risalgono
/// alla griglia che sincronizza l'header e le altre righe.
class _HScroll extends StatefulWidget {
  const _HScroll({required this.offset, required this.child});
  final double offset;
  final Widget child;
  @override
  State<_HScroll> createState() => _HScrollState();
}

class _HScrollState extends State<_HScroll> {
  late final ScrollController _c = ScrollController(initialScrollOffset: widget.offset);

  @override
  void didUpdateWidget(covariant _HScroll old) {
    super.didUpdateWidget(old);
    if (_c.hasClients && (_c.offset - widget.offset).abs() > 1 && !_c.position.isScrollingNotifier.value) {
      _c.jumpTo(widget.offset);
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
        controller: _c,
        scrollDirection: Axis.horizontal,
        child: widget.child,
      );
}

class _ProgramCell extends StatelessWidget {
  const _ProgramCell(this.p, {required this.channel});
  final EpgProgram p;
  final Channel channel;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final live = now.isAfter(p.start) && now.isBefore(p.stop);
    final past = now.isAfter(p.stop);
    return InkWell(
      onTap: () => _details(context),
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: live
              ? KairosColors.cyan.withOpacity(0.16)
              : past ? KairosColors.surface.withOpacity(0.5) : KairosColors.surface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: live ? KairosColors.cyan.withOpacity(0.6) : KairosColors.line),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [
          Text(p.title, maxLines: 1, overflow: TextOverflow.ellipsis,
              style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13,
                  color: past ? KairosColors.textDim : KairosColors.text)),
          Text('${DateFormat.Hm().format(p.start)} · ${p.duration.inMinutes} min',
              style: const TextStyle(color: KairosColors.textMute, fontSize: 11)),
        ]),
      ),
    );
  }

  void _details(BuildContext context) {
    final now = DateTime.now();
    final past = now.isAfter(p.stop);
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(12),
        child: GlassPanel(
          opacity: 0.92,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(p.title, style: Theme.of(ctx).textTheme.titleLarge),
            const SizedBox(height: 4),
            Text('${channel.name} · ${DateFormat('EEE d MMM HH:mm', 'it').format(p.start)} – ${DateFormat.Hm().format(p.stop)}',
                style: const TextStyle(color: KairosColors.textDim)),
            if (p.category != null) Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Chip(label: Text(p.category!), visualDensity: VisualDensity.compact),
            ),
            if (p.description != null) ...[
              const SizedBox(height: 10),
              Text(p.description!, maxLines: 6, overflow: TextOverflow.ellipsis),
            ],
            const SizedBox(height: 16),
            Row(children: [
              FilledButton.icon(
                onPressed: () { Navigator.pop(ctx); ctx.push('/play/${channel.id}'); },
                icon: const Icon(Icons.play_arrow_rounded),
                label: Text(past && channel.catchupDays > 0 ? 'Rivedi (catch-up)' : 'Guarda canale'),
              ),
            ]),
          ]),
        ),
      ),
    );
  }
}
