import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/download/download_manager.dart';
import '../../core/providers.dart';
import '../../core/theme/kairos_theme.dart';
import '../../shared/widgets/widgets.dart';

class DownloadsScreen extends ConsumerWidget {
  const DownloadsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dm = ref.watch(downloadManagerProvider);
    return SafeArea(
      bottom: false,
      child: ValueListenableBuilder<List<DownloadItem>>(
        valueListenable: dm.items,
        builder: (context, items, _) {
          final active = items.where((d) => d.status != DownloadStatus.done).toList();
          final done = items.where((d) => d.status == DownloadStatus.done).toList();
          final totalBytes = done.fold<int>(0, (a, d) => a + d.received);
          return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 4),
              child: Row(children: [
                Text('Download', style: Theme.of(context).textTheme.headlineMedium),
                const Spacer(),
                Text('${done.length} offline · ${fmtBytes(totalBytes)}',
                    style: const TextStyle(color: KairosColors.textDim)),
              ]),
            ),
            Expanded(
              child: items.isEmpty
                  ? const EmptyState(
                      icon: Icons.download_for_offline_outlined,
                      title: 'Nessun download',
                      subtitle: 'Tieni premuto un film o un episodio → "Scarica"')
                  : ListView(
                      padding: const EdgeInsets.only(bottom: 90),
                      children: [
                        if (active.isNotEmpty) ...[
                          const SectionHeader('In corso'),
                          for (final d in active) _DownloadTile(d, dm),
                        ],
                        if (done.isNotEmpty) ...[
                          const SectionHeader('Disponibili offline'),
                          for (final d in done) _DownloadTile(d, dm),
                        ],
                      ],
                    ),
            ),
          ]);
        },
      ),
    );
  }
}

class _DownloadTile extends StatelessWidget {
  const _DownloadTile(this.d, this.dm);
  final DownloadItem d;
  final DownloadManager dm;

  @override
  Widget build(BuildContext context) {
    final f = d.fraction;
    final subtitle = switch (d.status) {
      DownloadStatus.queued => 'In coda',
      DownloadStatus.running => '${fmtBytes(d.received)}${d.total > 0 ? ' / ${fmtBytes(d.total)}' : ''}'
          '${d.speedBps > 0 ? ' · ${fmtBytes(d.speedBps)}/s' : ''}'
          '${d.speedBps > 0 && d.total > 0 ? ' · ${_eta(d)}' : ''}',
      DownloadStatus.paused => 'In pausa · ${fmtBytes(d.received)}${d.total > 0 ? ' / ${fmtBytes(d.total)}' : ''}',
      DownloadStatus.done => '${fmtBytes(d.received)} · pronto offline',
      DownloadStatus.failed => d.error ?? 'Errore',
    };
    final color = switch (d.status) {
      DownloadStatus.failed => KairosColors.red,
      DownloadStatus.done => KairosColors.lime,
      _ => KairosColors.cyan,
    };

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: d.status == DownloadStatus.done ? () => context.push('/play/${d.channelId}') : null,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: SizedBox(
                width: 54, height: 76,
                child: d.logo != null && d.logo!.startsWith('http')
                    // locandina decodificata alla misura del riquadro (54 px), non all'originale
                    ? NetImage(d.logo!, fit: BoxFit.cover, decodeWidth: 108,
                        error: (_) => Container(color: KairosColors.surfaceHi))
                    : Container(color: KairosColors.surfaceHi, child: const Icon(Icons.movie_outlined)),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(d.name, maxLines: 2, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 6),
                if (d.status != DownloadStatus.done)
                  ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(
                      value: d.status == DownloadStatus.running && f == null ? null : (f ?? 0),
                      minHeight: 5,
                      backgroundColor: Colors.white12,
                      valueColor: AlwaysStoppedAnimation(color),
                    ),
                  ),
                const SizedBox(height: 6),
                Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: d.status == DownloadStatus.failed ? KairosColors.red : KairosColors.textDim, fontSize: 12.5)),
              ]),
            ),
            const SizedBox(width: 6),
            switch (d.status) {
              DownloadStatus.running => IconButton(onPressed: () => dm.pause(d.id), icon: const Icon(Icons.pause_rounded), tooltip: 'Pausa'),
              DownloadStatus.paused || DownloadStatus.queued => IconButton(onPressed: () => dm.resume(d.id), icon: const Icon(Icons.play_arrow_rounded), tooltip: 'Riprendi'),
              DownloadStatus.failed => IconButton(onPressed: () => dm.retry(d.id), icon: const Icon(Icons.refresh_rounded), tooltip: 'Riprova'),
              DownloadStatus.done => IconButton(onPressed: () => context.push('/play/${d.channelId}'), icon: const Icon(Icons.play_circle_fill_rounded, color: KairosColors.lime), tooltip: 'Guarda'),
            },
            IconButton(
              tooltip: 'Elimina',
              onPressed: () async {
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (_) => AlertDialog(
                    backgroundColor: KairosColors.surfaceHi,
                    title: Text('Eliminare "${d.name}"?'),
                    content: Text(d.status == DownloadStatus.done ? 'Il file verrà rimosso dal dispositivo.' : 'Il download verrà annullato.'),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Annulla')),
                      FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Elimina')),
                    ],
                  ),
                );
                if (ok == true) dm.delete(d.id);
              },
              icon: const Icon(Icons.delete_outline_rounded),
            ),
          ]),
        ),
      ),
    );
  }

  static String _eta(DownloadItem d) {
    final left = (d.total - d.received) / d.speedBps;
    if (left < 60) return '${left.round()} s';
    if (left < 3600) return '${(left / 60).round()} min';
    return '${(left / 3600).toStringAsFixed(1)} h';
  }
}
