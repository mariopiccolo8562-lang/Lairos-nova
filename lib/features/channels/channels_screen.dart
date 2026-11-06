import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/models/models.dart';
import '../../core/providers.dart';
import '../../core/theme/kairos_theme.dart';
import '../../shared/widgets/widgets.dart';

/// Lista canali a due pannelli: gruppi a sinistra, canali a destra.
/// La colonna canali è virtualizzata: chiede al DB solo le righe visibili.
class ChannelsScreen extends ConsumerStatefulWidget {
  const ChannelsScreen({super.key, required this.type, this.initialGroup});
  final ChannelType type;
  final String? initialGroup;

  @override
  ConsumerState<ChannelsScreen> createState() => _ChannelsScreenState();
}

class _ChannelsScreenState extends ConsumerState<ChannelsScreen> {
  String? _group; // null = tutti, '__fav' = preferiti
  bool _grid = false;

  @override
  void initState() {
    super.initState();
    _group = widget.initialGroup;
  }

  @override
  void didUpdateWidget(covariant ChannelsScreen old) {
    super.didUpdateWidget(old);
    if (old.initialGroup != widget.initialGroup) _group = widget.initialGroup;
  }

  @override
  Widget build(BuildContext context) {
    final groups = ref.watch(groupsProvider(widget.type));
    final wide = MediaQuery.sizeOf(context).width >= 760;
    final title = switch (widget.type) {
      ChannelType.live => 'Live TV',
      ChannelType.movie => 'Film',
      ChannelType.series => 'Serie TV',
      ChannelType.radio => 'Radio',
    };

    final groupsPanel = _GroupsPanel(
      groups: groups,
      selected: _group,
      onSelect: (g) => setState(() => _group = g),
    );

    final list = _ChannelList(
      key: ValueKey('$_group/${widget.type}/$_grid'),
      type: widget.type,
      group: _group,
      grid: _grid || widget.type == ChannelType.movie || widget.type == ChannelType.series,
    );

    return SafeArea(
      bottom: false,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 12, 8),
          child: Row(children: [
            Text(title, style: Theme.of(context).textTheme.headlineMedium),
            const SizedBox(width: 12),
            Text(_group == null ? 'Tutti' : (_group == '__fav' ? 'Preferiti' : _group!),
                style: const TextStyle(color: KairosColors.textDim)),
            const Spacer(),
            if (widget.type == ChannelType.live)
              IconButton(
                tooltip: _grid ? 'Vista lista' : 'Vista griglia',
                onPressed: () => setState(() => _grid = !_grid),
                icon: Icon(_grid ? Icons.view_list_rounded : Icons.grid_view_rounded),
              ),
            if (!wide)
              IconButton(
                tooltip: 'Gruppi',
                onPressed: () => showModalBottomSheet(
                  context: context,
                  backgroundColor: KairosColors.bgElevated,
                  isScrollControlled: true,
                  builder: (_) => SizedBox(
                    height: MediaQuery.sizeOf(context).height * 0.75,
                    child: _GroupsPanel(
                      groups: groups,
                      selected: _group,
                      onSelect: (g) {
                        Navigator.pop(context);
                        setState(() => _group = g);
                      },
                    ),
                  ),
                ),
                icon: const Icon(Icons.folder_open_rounded),
              ),
          ]),
        ),
        Expanded(
          child: wide
              ? Row(children: [
                  SizedBox(width: 280, child: groupsPanel),
                  const VerticalDivider(width: 1),
                  Expanded(child: list),
                ])
              : list,
        ),
      ]),
    );
  }
}

class _GroupsPanel extends StatelessWidget {
  const _GroupsPanel({required this.groups, required this.selected, required this.onSelect});
  final List<ChannelGroup> groups;
  final String? selected;
  final ValueChanged<String?> onSelect;

  @override
  Widget build(BuildContext context) {
    final fmt = NumberFormat.decimalPattern('it');
    final total = groups.fold<int>(0, (a, g) => a + g.count);
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 10),
      itemCount: groups.length + 2,
      itemExtent: 46,
      itemBuilder: (_, i) {
        if (i == 0) return _GroupRow('Tutti', total, selected == null, () => onSelect(null), icon: Icons.apps_rounded);
        if (i == 1) return _GroupRow('Preferiti', null, selected == '__fav', () => onSelect('__fav'), icon: Icons.favorite_rounded);
        final g = groups[i - 2];
        return _GroupRow(g.name, g.count, selected == g.name, () => onSelect(g.name), fmt: fmt);
      },
    );
  }
}

class _GroupRow extends StatefulWidget {
  const _GroupRow(this.name, this.count, this.selected, this.onTap, {this.icon, this.fmt});
  final String name;
  final int? count;
  final bool selected;
  final VoidCallback onTap;
  final IconData? icon;
  final NumberFormat? fmt;

  @override
  State<_GroupRow> createState() => _GroupRowState();
}

class _GroupRowState extends State<_GroupRow> {
  bool _focus = false;
  @override
  Widget build(BuildContext context) {
    final on = widget.selected;
    return FocusableActionDetector(
      onShowFocusHighlight: (f) => setState(() => _focus = f),
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) {
          widget.onTap();
          return null;
        })
      },
      child: InkWell(
        onTap: widget.onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            color: on ? KairosColors.cyan.withOpacity(0.12) : Colors.transparent,
            border: Border.all(color: _focus ? KairosColors.cyan : Colors.transparent),
          ),
          child: Row(children: [
            if (widget.icon != null) ...[
              Icon(widget.icon, size: 18, color: on ? KairosColors.cyan : KairosColors.textDim),
              const SizedBox(width: 10),
            ],
            Expanded(
              child: Text(widget.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontWeight: on ? FontWeight.w700 : FontWeight.w500,
                      color: on ? KairosColors.cyan : KairosColors.text)),
            ),
            if (widget.count != null)
              Text(widget.fmt?.format(widget.count) ?? '${widget.count}',
                  style: const TextStyle(color: KairosColors.textMute, fontSize: 12)),
          ]),
        ),
      ),
    );
  }
}

class _ChannelList extends ConsumerWidget {
  const _ChannelList({super.key, required this.type, required this.group, required this.grid});
  final ChannelType type;
  final String? group;
  final bool grid;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (group == '__fav') {
      final favs = ref.watch(favoritesProvider).where((c) => c.type == type).toList();
      if (favs.isEmpty) {
        return const EmptyState(
            icon: Icons.favorite_border, title: 'Nessun preferito',
            subtitle: 'Tieni premuto un canale per aggiungerlo');
      }
      return _buildFixed(context, favs);
    }

    final pl = ref.watch(activePlaylistIdProvider);
    final paged = ref.watch(pagedChannelsProvider(ChannelQuery(type: type, group: group, playlistId: pl)));
    if (paged.total == 0) {
      return const EmptyState(icon: Icons.tv_off_rounded, title: 'Nessun contenuto qui');
    }
    return _buildPaged(context, paged);
  }

  Widget _buildFixed(BuildContext context, List<Channel> items) {
    if (grid) {
      return _Grid(count: items.length, builder: (i) => ChannelCard(items[i], width: 160), poster: type != ChannelType.live);
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 90),
      itemCount: items.length,
      itemExtent: 72,
      itemBuilder: (_, i) => ChannelTile(items[i], autofocus: i == 0),
    );
  }

  Widget _buildPaged(BuildContext context, PagedChannels paged) {
    Widget cell(int i, {bool card = false}) {
      final c = paged.at(i);
      if (c == null) return const _Skeleton();
      return card ? ChannelCard(c, width: 160, autofocus: i == 0) : ChannelTile(c, autofocus: i == 0);
    }

    if (grid) {
      return _Grid(count: paged.total, builder: (i) => cell(i, card: true), poster: type != ChannelType.live);
    }
    return Scrollbar(
      interactive: true,
      thumbVisibility: paged.total > 300,
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 90),
        itemCount: paged.total,
        itemExtent: 72, // altezza fissa = scroll istantaneo anche a 300k righe
        cacheExtent: 600,
        itemBuilder: (_, i) => cell(i),
      ),
    );
  }
}

class _Grid extends StatelessWidget {
  const _Grid({required this.count, required this.builder, required this.poster});
  final int count;
  final Widget Function(int) builder;
  final bool poster;

  @override
  Widget build(BuildContext context) {
    final w = MediaQuery.sizeOf(context).width;
    final cols = (w / (poster ? 150 : 200)).floor().clamp(2, 10);
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 90),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: cols,
        mainAxisSpacing: 14,
        crossAxisSpacing: 12,
        childAspectRatio: poster ? 0.56 : 1.15,
      ),
      cacheExtent: 800,
      itemCount: count,
      itemBuilder: (_, i) => builder(i),
    );
  }
}

class _Skeleton extends StatelessWidget {
  const _Skeleton();
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(children: [
          Container(width: 46, height: 46,
              decoration: BoxDecoration(color: KairosColors.surface, borderRadius: BorderRadius.circular(12))),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Container(height: 12, width: 160, color: KairosColors.surface),
              const SizedBox(height: 8),
              Container(height: 10, width: 100, color: KairosColors.surface),
            ]),
          ),
        ]),
      );
}
