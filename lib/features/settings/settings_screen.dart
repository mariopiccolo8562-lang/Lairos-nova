import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/models/models.dart';
import '../../core/panel/panel_service.dart';
import '../../core/player/stream_engine.dart';
import '../../core/providers.dart';
import '../../core/theme/kairos_theme.dart';
import '../../core/xtream/xtream_api.dart';
import 'update_dialog.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});
  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  ImportProgress? _prog;
  int? _busyId;

  Future<void> _refresh(Playlist p) async {
    setState(() => _busyId = p.id);
    try {
      await ref.read(actionsProvider).importPlaylist(p, (x) => setState(() => _prog = x));
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Lista aggiornata')));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Errore: $e')));
    } finally {
      if (mounted) setState(() { _busyId = null; _prog = null; });
    }
  }

  Future<void> _refreshEpg() async {
    final s = ref.read(settingsProvider);
    final pl = ref.read(playlistsProvider).where((p) => p.id == ref.read(activePlaylistIdProvider)).firstOrNull;
    final url = s.epgUrlOverride ?? pl?.epgUrl;
    if (url == null || url.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Nessun URL EPG impostato')));
      return;
    }
    setState(() => _busyId = -1);
    await for (final x in ref.read(importServiceProvider).importEpg(url)) {
      if (mounted) setState(() => _prog = x);
    }
    ref.read(dataVersionProvider.notifier).state++;
    if (mounted) setState(() { _busyId = null; _prog = null; });
  }

  Future<void> _accountInfo(Playlist p) async {
    final api = XtreamApi(baseUrl: p.source, username: p.username!, password: p.password!);
    try {
      final a = await api.account();
      if (!mounted) return;
      showDialog(
        context: context,
        builder: (_) => AlertDialog(
          backgroundColor: KairosColors.surfaceHi,
          title: const Text('Account Xtream'),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Stato: ${a.status}${a.isTrial ? ' (trial)' : ''}'),
            Text('Scadenza: ${a.expiry == null ? '—' : DateFormat('d MMM yyyy', 'it').format(a.expiry!)}'
                '${a.daysLeft != null ? ' (${a.daysLeft} giorni)' : ''}'),
            Text('Connessioni: ${a.activeConnections}/${a.maxConnections}'),
          ]),
          actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK'))],
        ),
      );
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Errore: $e')));
    } finally {
      api.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(settingsProvider);
    final n = ref.read(settingsProvider.notifier);
    final upd = ref.watch(appUpdaterProvider);
    final panel = ref.watch(panelProvider);
    final playlists = ref.watch(playlistsProvider);
    final active = ref.watch(activePlaylistIdProvider);
    final db = ref.read(dbProvider);
    final fmt = NumberFormat.decimalPattern('it');
    final epgUpdated = db.get('epg_updated');

    return SafeArea(
      bottom: false,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 100),
        children: [
          Text('Impostazioni', style: Theme.of(context).textTheme.headlineMedium),
          const SizedBox(height: 16),

          _Section('Liste', trailing: TextButton.icon(
            onPressed: () => context.push('/import'),
            icon: const Icon(Icons.add_rounded), label: const Text('Aggiungi'))),
          for (final p in playlists)
            Card(
              child: ListTile(
                leading: Radio<int>(value: p.id, groupValue: active,
                    onChanged: (v) => ref.read(actionsProvider).setActivePlaylist(v!), activeColor: KairosColors.cyan),
                title: Text(p.name),
                subtitle: Text(_busyId == p.id && _prog != null
                    ? '${_prog!.phase} · ${fmt.format(_prog!.parsed)}'
                    : '${fmt.format(p.channelCount)} voci · ${p.kind.name} · '
                      '${p.lastSync == null ? 'mai sincronizzata' : DateFormat('d MMM HH:mm', 'it').format(p.lastSync!)}'),
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  if (p.kind == PlaylistKind.xtream)
                    IconButton(tooltip: 'Info account', onPressed: () => _accountInfo(p), icon: const Icon(Icons.badge_outlined)),
                  IconButton(
                    tooltip: 'Aggiorna',
                    onPressed: _busyId != null ? null : () => _refresh(p),
                    icon: _busyId == p.id
                        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.sync_rounded),
                  ),
                  IconButton(
                    tooltip: 'Elimina',
                    onPressed: () async {
                      final ok = await showDialog<bool>(
                        context: context,
                        builder: (_) => AlertDialog(
                          backgroundColor: KairosColors.surfaceHi,
                          title: Text('Eliminare "${p.name}"?'),
                          actions: [
                            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Annulla')),
                            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Elimina')),
                          ],
                        ),
                      );
                      if (ok == true) {
                        db.deletePlaylist(p.id);
                        ref.read(dataVersionProvider.notifier).state++;
                      }
                    },
                    icon: const Icon(Icons.delete_outline_rounded),
                  ),
                ]),
              ),
            ),

          _Section('Guida TV (EPG)'),
          Card(
            child: Column(children: [
              ListTile(
                title: const Text('URL EPG personalizzato'),
                subtitle: Text(s.epgUrlOverride ?? 'Usa quello della lista'),
                trailing: const Icon(Icons.edit_outlined),
                onTap: () async {
                  final c = TextEditingController(text: s.epgUrlOverride);
                  final v = await showDialog<String>(
                    context: context,
                    builder: (_) => AlertDialog(
                      backgroundColor: KairosColors.surfaceHi,
                      title: const Text('URL XMLTV'),
                      content: TextField(controller: c, decoration: const InputDecoration(hintText: 'https://…/epg.xml.gz')),
                      actions: [
                        TextButton(onPressed: () => Navigator.pop(context, ''), child: const Text('Rimuovi')),
                        FilledButton(onPressed: () => Navigator.pop(context, c.text.trim()), child: const Text('Salva')),
                      ],
                    ),
                  );
                  if (v != null) n.update((x) => x.copyWith(epgUrlOverride: v.isEmpty ? null : v));
                },
              ),
              ListTile(
                title: const Text('Aggiorna guida adesso'),
                subtitle: Text(_busyId == -1 && _prog != null
                    ? '${_prog!.phase} · ${fmt.format(_prog!.parsed)} programmi'
                    : epgUpdated == null ? 'Mai scaricata'
                        : 'Ultimo aggiornamento ${DateFormat('d MMM HH:mm', 'it').format(DateTime.fromMillisecondsSinceEpoch(int.parse(epgUpdated)))}'),
                trailing: _busyId == -1
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.download_rounded),
                onTap: _busyId != null ? null : _refreshEpg,
              ),
            ]),
          ),

          _Section('Riproduzione'),
          Card(
            child: Column(children: [
              ListTile(
                title: const Text('Profilo buffer'),
                subtitle: Text((switch (s.bufferProfile) {
                  BufferProfile.lowLatency => 'Bassa latenza (4s) · per sport e connessioni ottime',
                  BufferProfile.balanced => 'Bilanciato (12s) · consigliato',
                  BufferProfile.stable => 'Massima stabilità (30s) · per Wi-Fi debole o server lenti',
                }) + (panel.imposed('p.buffer') ? ' · scelto dal fornitore' : '')),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: SegmentedButton<BufferProfile>(
                  segments: const [
                    ButtonSegment(value: BufferProfile.lowLatency, label: Text('Veloce'), icon: Icon(Icons.bolt_rounded)),
                    ButtonSegment(value: BufferProfile.balanced, label: Text('Bilanciato'), icon: Icon(Icons.balance_rounded)),
                    ButtonSegment(value: BufferProfile.stable, label: Text('Stabile'), icon: Icon(Icons.shield_rounded)),
                  ],
                  selected: {s.bufferProfile},
                  onSelectionChanged: panel.imposed('p.buffer') ? null : (v) => n.update((x) => x.copyWith(bufferProfile: v.first)),
                ),
              ),
              SwitchListTile(
                title: const Text('Overlay diagnostica'),
                subtitle: const Text('Risoluzione, bitrate, buffer, frame persi'),
                value: s.showHealthOverlay,
                activeColor: KairosColors.cyan,
                onChanged: (v) => n.update((x) => x.copyWith(showHealthOverlay: v)),
              ),
              SwitchListTile(
                title: const Text('Modalità TV'),
                subtitle: Text('Interfaccia ottimizzata per telecomando${panel.imposed('tvmode') ? ' · scelta dal fornitore' : ''}'),
                value: s.tvMode,
                activeColor: KairosColors.cyan,
                onChanged: panel.imposed('tvmode') ? null : (v) => n.update((x) => x.copyWith(tvMode: v)),
              ),
            ]),
          ),

          _Section('Contenuti'),
          Card(
            child: Column(children: [
              ListTile(
                title: const Text('Gruppi nascosti'),
                subtitle: Text(s.hiddenGroups.isEmpty ? 'Nessuno' : '${s.hiddenGroups.length} gruppi nascosti'),
                trailing: s.hiddenGroups.isEmpty ? null : TextButton(
                    onPressed: () => n.update((x) => x.copyWith(hiddenGroups: {})), child: const Text('Mostra tutti')),
              ),
              ListTile(
                title: const Text('PIN parental control'),
                subtitle: Text(s.parentalPin == null ? 'Disattivato' : 'Attivo'),
                trailing: const Icon(Icons.lock_outline_rounded),
                onTap: () async {
                  final c = TextEditingController();
                  final v = await showDialog<String>(
                    context: context,
                    builder: (_) => AlertDialog(
                      backgroundColor: KairosColors.surfaceHi,
                      title: const Text('Imposta PIN (4 cifre)'),
                      content: TextField(controller: c, keyboardType: TextInputType.number, maxLength: 4, obscureText: true),
                      actions: [
                        TextButton(onPressed: () => Navigator.pop(context, ''), child: const Text('Disattiva')),
                        FilledButton(onPressed: () => Navigator.pop(context, c.text), child: const Text('Salva')),
                      ],
                    ),
                  );
                  if (v != null) n.update((x) => v.length == 4 ? x.copyWith(parentalPin: v) : x.copyWith(clearPin: true));
                },
              ),
            ]),
          ),

          _Section('Fornitore'),
          Card(
            child: panel.linked
                ? Column(children: [
                    ListTile(
                      title: Text('Codice ${panel.code}'),
                      subtitle: Text(panel.state == null
                          ? (panel.lastError ?? 'Collegamento al pannello…')
                          : '${panel.state!.statusLabel}${panel.state!.name.isNotEmpty ? ' · ${panel.state!.name}' : ''}${panel.state!.expires.isNotEmpty ? ' · scade il ${panel.state!.expiresLabel}' : ''}'
                              '${panel.providerPlaylistIds.isEmpty ? '' : ' · ${panel.providerPlaylistIds.length} liste dal fornitore'}'),
                      trailing: panel.busy
                          ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                          : IconButton(tooltip: 'Aggiorna dal fornitore', onPressed: () => panel.refresh(), icon: const Icon(Icons.sync_rounded)),
                    ),
                    if (panel.lastError != null && panel.state != null)
                      Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 8), child: Text(panel.lastError!, style: const TextStyle(color: KairosColors.amber, fontSize: 12))),
                    ListTile(
                      title: const Text('Scollega dal fornitore'),
                      subtitle: const Text('Le liste del fornitore vengono rimosse; quelle aggiunte da te restano'),
                      trailing: const Icon(Icons.link_off_rounded),
                      onTap: () async {
                        final ok = await showDialog<bool>(
                          context: context,
                          builder: (_) => AlertDialog(
                            backgroundColor: KairosColors.surfaceHi,
                            title: const Text('Scollegare dal fornitore?'),
                            content: const Text('Per ricollegarti servirà un nuovo codice da comunicare al fornitore.'),
                            actions: [
                              TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Annulla')),
                              FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Scollega')),
                            ],
                          ),
                        );
                        if (ok == true) await panel.unlink();
                      },
                    ),
                  ])
                : ListTile(
                    title: const Text('Collega al tuo fornitore'),
                    subtitle: const Text('Con un codice: le liste arrivano da sole e restano aggiornate'),
                    trailing: const Icon(Icons.qr_code_2_rounded),
                    onTap: () => context.push('/import?tab=3'),
                  ),
          ),

          _Section('Aggiornamenti'),
          Card(
            child: Column(children: [
              ListTile(
                title: const Text('Aggiornamenti dell\'app'),
                subtitle: Text(upd.pending == null
                    ? (upd.message ?? 'Versione installata ${upd.currentVersion.isEmpty ? '—' : upd.currentVersion} · tocca per controllare')
                    : upd.ready
                        ? 'Versione ${upd.pending!.version} scaricata: tocca per installare'
                        : 'Versione ${upd.pending!.version} disponibile: tocca per aggiornare'),
                trailing: Icon(upd.pending == null ? Icons.refresh_rounded : Icons.system_update_rounded,
                    color: upd.pending == null ? null : KairosColors.cyan),
                onTap: () async {
                  if (upd.pending != null) {
                    await showUpdateDialog(context, upd);
                    return;
                  }
                  await upd.check(manual: true); // se c'è una versione nuova la finestra arriva da sola
                },
              ),
              SwitchListTile(
                title: const Text('Aggiornamenti in background'),
                subtitle: Text((upd.bgUpdate
                        ? 'La versione nuova si scarica da sola su Wi-Fi o cavo: a te resta solo «Installa»'
                        : 'La versione nuova si scarica solo quando accetti') +
                    (upd.bgImposed ? ' · scelto dal fornitore' : '')),
                value: upd.bgUpdate,
                activeColor: KairosColors.cyan,
                onChanged: upd.bgImposed ? null : (v) => upd.setBgUpdate(v),
              ),
            ]),
          ),

          _Section('Info'),
          Card(
            child: ListTile(
              title: Text('Kairos Nova ${upd.currentVersion.isEmpty ? '' : upd.currentVersion}'),
              subtitle: const Text('Motore libmpv · database SQLite FTS5 · parser streaming in isolate.\n'
                  'Progettato per liste da 300.000+ canali senza rallentamenti.'),
              isThreeLine: true,
            ),
          ),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section(this.title, {this.trailing});
  final String title;
  final Widget? trailing;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 18, 4, 8),
        child: Row(children: [
          Text(title.toUpperCase(), style: Theme.of(context).textTheme.labelSmall),
          const Spacer(),
          if (trailing != null) trailing!,
        ]),
      );
}
