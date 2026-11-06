import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/models/models.dart';
import '../../core/providers.dart';
import '../../core/theme/kairos_theme.dart';
import '../../shared/widgets/widgets.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playlists = ref.watch(playlistsProvider);
    final active = ref.watch(activePlaylistIdProvider);
    // recentProvider cambia solo quando parte un canale (non a ogni tick del lettore); il COUNT è in un provider
    final recent = ref.watch(recentProvider);
    final favs = ref.watch(favoritesProvider);
    final liveGroups = ref.watch(groupsProvider(ChannelType.live));
    final movieGroups = ref.watch(groupsProvider(ChannelType.movie));
    final total = ref.watch(totalCountProvider);
    final hero = recent.isNotEmpty ? recent.first : (favs.isNotEmpty ? favs.first : null);

    final wide = MediaQuery.sizeOf(context).width >= 760;

    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: _Hero(
            channel: hero,
            total: total,
            playlistName: playlists.where((p) => p.id == active).firstOrNull?.name,
            wide: wide,
          ),
        ),
        if (recent.isNotEmpty) ...[
          const SliverToBoxAdapter(child: SectionHeader('Continua a guardare')),
          SliverToBoxAdapter(child: _Row(recent, height: 170)),
        ],
        if (favs.isNotEmpty) ...[
          SliverToBoxAdapter(
              child: SectionHeader('Preferiti',
                  action: 'Tutti', onAction: () => context.go('/live?g=__fav'))),
          SliverToBoxAdapter(child: _Row(favs, height: 170)),
        ],
        if (liveGroups.isNotEmpty) ...[
          SliverToBoxAdapter(
              child: SectionHeader('Canali TV',
                  action: '${liveGroups.length} gruppi', onAction: () => context.go('/live'))),
          SliverToBoxAdapter(child: _GroupChips(liveGroups, base: '/live')),
          SliverToBoxAdapter(child: _GroupPreview(liveGroups.first, active)),
        ],
        if (movieGroups.isNotEmpty) ...[
          SliverToBoxAdapter(
              child: SectionHeader('Film',
                  action: 'Esplora', onAction: () => context.go('/movies'))),
          SliverToBoxAdapter(child: _GroupPreview(movieGroups.first, active, poster: true)),
        ],
        const SliverPadding(padding: EdgeInsets.only(bottom: 90)),
      ],
    );
  }
}

class _Hero extends ConsumerWidget {
  const _Hero({this.channel, required this.total, this.playlistName, required this.wide});
  final Channel? channel;
  final int total;
  final String? playlistName;
  final bool wide;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final nn = channel == null ? const NowNext() : ref.watch(nowNextProvider(channel!.tvgId));
    final now = DateTime.now();
    return Container(
      height: wide ? 360 : 300,
      padding: EdgeInsets.fromLTRB(20, MediaQuery.paddingOf(context).top + 18, 20, 20),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const PlasmaText('KAIROS NOVA',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w900, letterSpacing: 4)),
          const Spacer(),
          Text(DateFormat('EEE d MMM · HH:mm', 'it').format(now).toUpperCase(),
              style: Theme.of(context).textTheme.labelSmall),
        ]),
        const Spacer(),
        if (channel != null) ...[
          Text('RIPRENDI', style: Theme.of(context).textTheme.labelSmall),
          const SizedBox(height: 6),
          Text(channel!.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.displayLarge?.copyWith(fontSize: wide ? 48 : 34)),
          if (nn.now != null) ...[
            const SizedBox(height: 4),
            Text(nn.now!.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: KairosColors.textDim, fontSize: 16)),
          ],
          const SizedBox(height: 16),
          Row(children: [
            FilledButton.icon(
              autofocus: true,
              onPressed: () => context.push('/play/${channel!.id}'),
              icon: const Icon(Icons.play_arrow_rounded),
              label: const Text('Guarda ora'),
            ),
            const SizedBox(width: 12),
            OutlinedButton.icon(
              onPressed: () => context.go('/guide'),
              icon: const Icon(Icons.calendar_view_day_rounded, size: 18),
              label: const Text('Guida TV'),
            ),
          ]),
        ] else ...[
          Text('Benvenuto', style: Theme.of(context).textTheme.displayLarge),
          const SizedBox(height: 6),
          Text(
            total == 0
                ? 'Aggiungi una lista per iniziare'
                : '${NumberFormat.decimalPattern('it').format(total)} contenuti pronti · $playlistName',
            style: const TextStyle(color: KairosColors.textDim, fontSize: 16),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            autofocus: true,
            onPressed: () => context.go(total == 0 ? '/import' : '/live'),
            icon: Icon(total == 0 ? Icons.add_rounded : Icons.live_tv_rounded),
            label: Text(total == 0 ? 'Aggiungi lista' : 'Vai ai canali'),
          ),
        ],
      ]),
    ).animate().fadeIn(duration: 400.ms).slideY(begin: 0.04, end: 0, curve: Curves.easeOutCubic);
  }
}

class _Row extends StatelessWidget {
  const _Row(this.items, {required this.height});
  final List<Channel> items;
  final double height;

  @override
  Widget build(BuildContext context) => SizedBox(
        height: height + 44,
        child: ListView.separated(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          scrollDirection: Axis.horizontal,
          itemCount: items.length,
          cacheExtent: 400,
          separatorBuilder: (_, __) => const SizedBox(width: 12),
          itemBuilder: (_, i) => ChannelCard(items[i], width: height * 16 / 9 * 0.62),
        ),
      );
}

class _GroupChips extends StatelessWidget {
  const _GroupChips(this.groups, {required this.base});
  final List<ChannelGroup> groups;
  final String base;

  @override
  Widget build(BuildContext context) => SizedBox(
        height: 40,
        child: ListView.separated(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          scrollDirection: Axis.horizontal,
          itemCount: groups.length.clamp(0, 40),
          separatorBuilder: (_, __) => const SizedBox(width: 8),
          itemBuilder: (_, i) => ActionChip(
            label: Text('${groups[i].name} · ${groups[i].count}'),
            onPressed: () => context.go('$base?g=${Uri.encodeComponent(groups[i].name)}'),
            backgroundColor: KairosColors.surface,
            side: const BorderSide(color: KairosColors.line),
          ),
        ),
      );
}

class _GroupPreview extends ConsumerWidget {
  const _GroupPreview(this.group, this.playlistId, {this.poster = false});
  final ChannelGroup group;
  final int? playlistId;
  final bool poster;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final items = ref.watch(dbProvider).channelsPage(
        playlistId: playlistId, type: group.type, group: group.name, offset: 0, limit: 20);
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: SizedBox(
        height: poster ? 290 : 160,
        child: ListView.separated(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          scrollDirection: Axis.horizontal,
          itemCount: items.length,
          separatorBuilder: (_, __) => const SizedBox(width: 12),
          itemBuilder: (_, i) => ChannelCard(items[i], width: poster ? 150 : 190),
        ),
      ),
    );
  }
}
