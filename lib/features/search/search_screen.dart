import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/models/models.dart';
import '../../core/providers.dart';
import '../../core/theme/kairos_theme.dart';
import '../../shared/widgets/widgets.dart';

/// Ricerca istantanea full-text su canali + programmi EPG.
/// Debounce 120 ms; la query FTS5 risponde in pochi ms su 300k righe.
class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});
  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  final _ctrl = TextEditingController();
  Timer? _debounce;
  List<EpgProgram> _programs = const [];

  @override
  void initState() {
    super.initState();
    _ctrl.text = ref.read(searchQueryProvider);
  }

  void _onChanged(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 120), () {
      ref.read(searchQueryProvider.notifier).state = v;
      setState(() {
        _programs = v.trim().length >= 3 ? ref.read(dbProvider).searchPrograms(v.trim(), limit: 40) : const [];
      });
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final results = ref.watch(searchResultsProvider);
    final q = ref.watch(searchQueryProvider);
    final byType = <ChannelType, List<Channel>>{};
    for (final c in results) {
      (byType[c.type] ??= []).add(c);
    }

    return SafeArea(
      bottom: false,
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 8),
          child: TextField(
            controller: _ctrl,
            autofocus: true,
            onChanged: _onChanged,
            textInputAction: TextInputAction.search,
            style: const TextStyle(fontSize: 18),
            decoration: InputDecoration(
              hintText: 'Cerca canali, film, serie, programmi…',
              prefixIcon: const Icon(Icons.search_rounded, color: KairosColors.cyan),
              suffixIcon: q.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.close_rounded),
                      onPressed: () {
                        _ctrl.clear();
                        _onChanged('');
                      }),
            ),
          ),
        ),
        Expanded(
          child: q.trim().length < 2
              ? const EmptyState(
                  icon: Icons.manage_search_rounded,
                  title: 'Digita almeno 2 lettere',
                  subtitle: 'Trova "sky sp" → Sky Sport, cerca anche nei programmi in onda')
              : results.isEmpty && _programs.isEmpty
                  ? const EmptyState(icon: Icons.search_off_rounded, title: 'Nessun risultato')
                  : ListView(
                      padding: const EdgeInsets.only(bottom: 90),
                      children: [
                        for (final e in byType.entries) ...[
                          SectionHeader('${_label(e.key)} · ${e.value.length}'),
                          for (final c in e.value.take(60)) ChannelTile(c, showGroup: true),
                        ],
                        if (_programs.isNotEmpty) ...[
                          SectionHeader('Programmi · ${_programs.length}'),
                          for (final p in _programs) _ProgramTile(p),
                        ],
                      ],
                    ),
        ),
      ]),
    );
  }

  static String _label(ChannelType t) => switch (t) {
        ChannelType.live => 'Canali',
        ChannelType.movie => 'Film',
        ChannelType.series => 'Serie',
        ChannelType.radio => 'Radio',
      };
}

class _ProgramTile extends ConsumerWidget {
  const _ProgramTile(this.p);
  final EpgProgram p;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final db = ref.read(dbProvider);
    final fmt = DateFormat('EEE HH:mm', 'it');
    final live = DateTime.now().isAfter(p.start) && DateTime.now().isBefore(p.stop);
    return ListTile(
      leading: Container(
        width: 46, height: 46,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          color: live ? KairosColors.red.withOpacity(0.18) : KairosColors.surface,
        ),
        alignment: Alignment.center,
        child: Icon(live ? Icons.sensors_rounded : Icons.schedule_rounded,
            color: live ? KairosColors.red : KairosColors.textDim),
      ),
      title: Text(p.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text('${fmt.format(p.start)} – ${DateFormat.Hm().format(p.stop)} · ${p.tvgId}',
          style: const TextStyle(color: KairosColors.textDim, fontSize: 12)),
      onTap: () {
        final rows = db.search(p.tvgId, limit: 1);
        final ch = rows.isNotEmpty ? rows.first : null;
        if (ch != null) {
          context.push('/play/${ch.id}');
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Canale non trovato nella lista')));
        }
      },
    );
  }
}
