import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'core/models/models.dart';
import 'core/providers.dart';
import 'core/theme/kairos_theme.dart';
import 'features/channels/channels_screen.dart';
import 'features/downloads/downloads_screen.dart';
import 'features/guide/guide_screen.dart';
import 'features/home/home_screen.dart';
import 'features/home/shell.dart';
import 'features/import/import_screen.dart';
import 'features/multiview/multiview_screen.dart';
import 'features/player/player_screen.dart';
import 'features/search/search_screen.dart';
import 'features/settings/settings_screen.dart';

final _routerProvider = Provider<GoRouter>((ref) {
  final hasPlaylist = ref.read(playlistsProvider).isNotEmpty;
  return GoRouter(
    initialLocation: hasPlaylist ? '/' : '/import?first=1',
    routes: [
      ShellRoute(
        builder: (context, state, child) => AppShell(child: child),
        routes: [
          GoRoute(path: '/', builder: (_, __) => const HomeScreen()),
          GoRoute(
            path: '/live',
            builder: (_, s) => ChannelsScreen(
                type: ChannelType.live, initialGroup: s.uri.queryParameters['g']),
          ),
          GoRoute(
            path: '/movies',
            builder: (_, s) => ChannelsScreen(
                type: ChannelType.movie, initialGroup: s.uri.queryParameters['g']),
          ),
          GoRoute(
            path: '/series',
            builder: (_, s) => ChannelsScreen(
                type: ChannelType.series, initialGroup: s.uri.queryParameters['g']),
          ),
          GoRoute(path: '/guide', builder: (_, __) => const GuideScreen()),
          GoRoute(path: '/search', builder: (_, __) => const SearchScreen()),
          GoRoute(path: '/downloads', builder: (_, __) => const DownloadsScreen()),
          GoRoute(path: '/settings', builder: (_, __) => const SettingsScreen()),
        ],
      ),
      GoRoute(
        path: '/import',
        builder: (_, s) => ImportScreen(first: s.uri.queryParameters['first'] == '1'),
      ),
      GoRoute(
        path: '/play/:id',
        pageBuilder: (_, s) => CustomTransitionPage(
          child: PlayerScreen(channelId: int.parse(s.pathParameters['id']!)),
          transitionsBuilder: (_, a, __, child) =>
              FadeTransition(opacity: a, child: child),
          transitionDuration: const Duration(milliseconds: 220),
        ),
      ),
      GoRoute(path: '/multiview', builder: (_, __) => const MultiviewScreen()),
    ],
  );
});

class KairosApp extends ConsumerWidget {
  const KairosApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp.router(
      title: 'Kairos Nova',
      debugShowCheckedModeBanner: false,
      theme: KairosTheme.dark(),
      routerConfig: ref.watch(_routerProvider),
      // Scroll fluido anche su Android TV / telecomando.
      scrollBehavior: const MaterialScrollBehavior().copyWith(
        physics: const BouncingScrollPhysics(),
        scrollbars: false,
      ),
    );
  }
}
