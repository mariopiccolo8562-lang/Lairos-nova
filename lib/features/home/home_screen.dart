import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/home_rules.dart';
import '../../core/models/models.dart';
import '../../core/parental.dart';
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
    final recentAll = ref.watch(recentProvider);
    final favsAll = ref.watch(favoritesProvider);
    // adulti fuori dalla Home (rc «adult» diverso da «on»): righe senza canali, film e serie per adulti
    final recent = ref.watch(homeRecentProvider);
    final favs = ref.watch(homeFavoritesProvider);
    final allLive = ref.watch(groupsProvider(ChannelType.live));
    final allMovies = ref.watch(groupsProvider(ChannelType.movie));
    // Home decisa dal pannello: gruppi in primo piano (home.top) e nascosti (home.hide); senza regole come sempre.
    // Con gli adulti fuori dalla Home i gruppi per adulti contano come nascosti
    final rules = ref.watch(homeRulesProvider);
    final chosen = rules.top.isEmpty
        ? const <ChannelGroup>[]
        : rules.pickTop([allLive, allMovies, ref.watch(groupsProvider(ChannelType.series))]);
    // controllo genitori: un gruppo per adulti ancora protetto non diventa una riga in primo piano
    final parentalOn = ref.watch(settingsProvider.select((s) => s.parentalOn));
    final unlocked = ref.watch(parentalUnlockedProvider);
    final top = [for (final g in chosen) if (!(parentalOn && !unlocked && isAdultGroup(g.name))) g];
    bool usual(ChannelGroup g) => !rules.hidden(g.name) && !chosen.contains(g);
    // chip dei gruppi: niente nascosti, prima quelli in primo piano
    final liveGroups = rules.order([for (final g in allLive) if (!rules.hidden(g.name)) g]);
    final livePreview = allLive.where(usual).firstOrNull;
    final moviePreview = allMovies.where(usual).firstOrNull;
    // titolo in evidenza: mai un canale di un gruppo nascosto né, con gli adulti fuori dalla Home, per adulti; se i
    // canali da riprendere erano tutti da togliere, il primo titolo delle altre righe della Home
    var hero = rules.hero(recentAll, favsAll);
    if (hero == null && rules.heroFromRows(recentAll, favsAll)) {
      for (final g in [...top, if (livePreview != null) livePreview, if (moviePreview != null) moviePreview]) {
        final row = ref.watch(homeGroupPreviewProvider(_query(g, active)));
        if (row.isNotEmpty) {
          hero = row.first;
          break;
        }
      }
    }

    final wide = MediaQuery.sizeOf(context).width >= 760;

    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: _Hero(
            channel: hero,
            playlistName: playlists.where((p) => p.id == active).firstOrNull?.name,
            wide: wide,
          ),
        ),
        if (recent.isNotEmpty) ...[
          const SliverToBoxAdapter(child: SectionHeader('Continua a guardare')),
          SliverToBoxAdapter(child: _Row(recent, height: 170)),
        ],
        // gruppi in primo piano subito dopo «Continua a guardare», prima di tutte le altre righe (una riga rimasta
        // vuota senza gli elementi per adulti sparisce con la sua intestazione)
        for (final g in top)
          SliverToBoxAdapter(
            child: _GroupPreview(
              g,
              active,
              poster: g.type == ChannelType.movie || g.type == ChannelType.series,
              header: SectionHeader(g.name,
                  action: 'Tutti', onAction: () => context.go('${_base(g.type)}?g=${Uri.encodeComponent(g.name)}')),
            ),
          ),
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
          if (livePreview != null) SliverToBoxAdapter(child: _GroupPreview(livePreview, active)),
        ],
        if (moviePreview != null)
          SliverToBoxAdapter(
            child: _GroupPreview(
              moviePreview,
              active,
              poster: true,
              header: SectionHeader('Film', action: 'Esplora', onAction: () => context.go('/movies')),
            ),
          ),
        const SliverPadding(padding: EdgeInsets.only(bottom: 90)),
      ],
    );
  }
}

/// Pagina degli elenchi per il tipo del gruppo («Tutti» di una riga in primo piano).
String _base(ChannelType? type) => switch (type) {
      ChannelType.movie => '/movies',
      ChannelType.series => '/series',
      _ => '/live',
    };

/// Prime voci del gruppo per la sua riga della Home (la stessa richiesta della riga e del titolo in evidenza).
ChannelQuery _query(ChannelGroup g, int? playlistId) => ChannelQuery(type: g.type, group: g.name, playlistId: playlistId);

class _Hero extends ConsumerWidget {
  const _Hero({this.channel, this.playlistName, required this.wide});
  final Channel? channel;
  final String? playlistName;
  final bool wide;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final nn = channel == null ? const NowNext() : ref.watch(nowNextProvider(channel!.tvgId));
    // il totale (COUNT su centinaia di migliaia di righe) serve solo al benvenuto, senza un titolo da riprendere
    final total = channel == null ? ref.watch(totalCountProvider) : 0;
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
  const _GroupPreview(this.group, this.playlistId, {this.poster = false, this.header});
  final ChannelGroup group;
  final int? playlistId;
  final bool poster;

  /// Intestazione della riga: si mostra solo se la riga ha qualcosa.
  final Widget? header;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // senza gli elementi per adulti (con il filtro attivo): una riga rimasta vuota non si mostra
    final items = ref.watch(homeGroupPreviewProvider(_query(group, playlistId)));
    if (items.isEmpty) return const SizedBox.shrink();
    final row = Padding(
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
    final h = header;
    if (h == null) return row;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [h, row]);
  }
}
