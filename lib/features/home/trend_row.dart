import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/home_rules.dart';
import '../../core/models/models.dart';
import '../../core/panel/panel_service.dart';
import '../../core/parental.dart';
import '../../core/providers.dart';
import '../../core/trend_match.dart';
import '../../shared/widgets/widgets.dart';

/// Titoli di tendenza della settimana (classifica del pannello) che la playlist in uso ha davvero, nell'ordine della
/// classifica (13 novembre 2026). Vuota se la classifica non c'è, se la voce «o.homeArt» del pannello è «off» o se
/// nessun titolo corrisponde: allora la riga non si mostra.
final trendRowProvider = FutureProvider.autoDispose.family<List<Channel>, ChannelType>((ref, type) async {
  ref.watch(dataVersionProvider);
  final on = ref.watch(panelProvider.select((p) => p.remoteConfig['o.homeArt'] != 'off'));
  if (!on) return const <Channel>[];
  final active = ref.watch(activePlaylistIdProvider);
  final rules = ref.watch(homeRulesProvider);
  final hideAdult = ref.watch(panelProvider.select((p) => adultHiddenFromHome(p.remoteConfig['adult'])));
  final parentalOn = ref.watch(settingsProvider.select((s) => s.parentalOn));
  final unlocked = ref.watch(parentalUnlockedProvider);
  final trend = await ref.read(panelProvider).trending();
  final titles = type == ChannelType.series ? trend.series : trend.movies;
  if (titles.isEmpty) return const <Channel>[];
  final db = ref.read(dbProvider);
  final out = <Channel>[];
  final seen = <int>{};
  for (final t in titles) {
    if (out.length >= 15) break;
    for (final c in db.search(t.title, type: type, limit: 8)) {
      if (active != null && c.playlistId != active) continue;
      if (rules.hidden(c.groupName) || (hideAdult && isAdultChannel(c))) continue;
      if (parentalOn && !unlocked && isAdultGroup(c.groupName)) continue;
      if (titleMatches(c.name, yearFromName(c.name), t.title, t.year) && seen.add(c.id)) {
        out.add(c);
        break;
      }
    }
  }
  return out;
});

/// Riga «Film / Serie di tendenza questa settimana» della Home: locandine come le righe dei gruppi.
class TrendRow extends ConsumerWidget {
  const TrendRow(this.type, this.title, {super.key});
  final ChannelType type;
  final String title;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final items = ref.watch(trendRowProvider(type)).valueOrNull ?? const <Channel>[];
    if (items.isEmpty) return const SizedBox.shrink();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SectionHeader(title),
      Padding(
        padding: const EdgeInsets.only(top: 12),
        child: SizedBox(
          height: 290,
          child: ListView.separated(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            scrollDirection: Axis.horizontal,
            itemCount: items.length,
            separatorBuilder: (_, __) => const SizedBox(width: 12),
            itemBuilder: (_, i) => ChannelCard(items[i], width: 150),
          ),
        ),
      ),
    ]);
  }
}
