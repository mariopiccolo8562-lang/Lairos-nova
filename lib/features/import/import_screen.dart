import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/models/models.dart';
import '../../core/providers.dart';
import '../../core/theme/kairos_theme.dart';
import '../../core/xtream/xtream_api.dart';

/// Onboarding + aggiunta liste: URL M3U, file locale, Xtream Codes.
/// Mostra progresso reale (canali analizzati, MB scaricati, fase).
class ImportScreen extends ConsumerStatefulWidget {
  const ImportScreen({super.key, this.first = false});
  final bool first;
  @override
  ConsumerState<ImportScreen> createState() => _ImportScreenState();
}

class _ImportScreenState extends ConsumerState<ImportScreen> with SingleTickerProviderStateMixin {
  late final _tabs = TabController(length: 3, vsync: this);
  final _name = TextEditingController();
  final _url = TextEditingController();
  final _epg = TextEditingController();
  final _host = TextEditingController();
  final _user = TextEditingController();
  final _pass = TextEditingController();
  String? _filePath;
  ImportProgress? _progress;
  bool _busy = false;

  @override
  void dispose() {
    _tabs.dispose();
    for (final c in [_name, _url, _epg, _host, _user, _pass]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _start() async {
    final db = ref.read(dbProvider);
    final kind = PlaylistKind.values[_tabs.index == 0 ? 0 : _tabs.index == 1 ? 1 : 2];
    String source;
    String? epgUrl = _epg.text.trim().isEmpty ? null : _epg.text.trim();
    String? user, pass;

    switch (kind) {
      case PlaylistKind.m3uUrl:
        source = _url.text.trim();
        if (!source.startsWith('http')) return _err('Inserisci un URL valido (http/https)');
      case PlaylistKind.m3uFile:
        if (_filePath == null) return _err('Seleziona un file M3U');
        source = _filePath!;
      case PlaylistKind.xtream:
        var h = _host.text.trim();
        if (h.isEmpty || _user.text.isEmpty || _pass.text.isEmpty) return _err('Compila server, utente e password');
        if (!h.startsWith('http')) h = 'http://$h';
        source = h.replaceAll(RegExp(r'/+$'), '');
        user = _user.text.trim();
        pass = _pass.text.trim();
        epgUrl ??= XtreamApi(baseUrl: source, username: user, password: pass).xmltvUrl();
    }

    final name = _name.text.trim().isEmpty ? 'Lista ${db.playlists().length + 1}' : _name.text.trim();
    setState(() { _busy = true; _progress = const ImportProgress(phase: 'Avvio…'); });

    final id = db.insertPlaylist(name: name, kind: kind, source: source, epgUrl: epgUrl, username: user, password: pass);
    final pl = db.playlist(id)!;
    try {
      await ref.read(actionsProvider).importPlaylist(pl, (p) {
        if (mounted) setState(() => _progress = p);
      });
      ref.read(actionsProvider).setActivePlaylist(id);
      if (!mounted) return;
      context.go('/');
    } catch (e) {
      db.deletePlaylist(id);
      ref.read(dataVersionProvider.notifier).state++;
      if (mounted) setState(() { _busy = false; });
      _err(e.toString().replaceFirst('Exception: ', ''));
    }
  }

  void _err(String m) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(m),
      backgroundColor: KairosColors.red.withOpacity(0.9),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final fmt = NumberFormat.decimalPattern('it');
    return Scaffold(
      body: Stack(children: [
        Positioned.fill(child: Container(color: KairosColors.bg)),
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: ListView(
              padding: const EdgeInsets.all(24),
              shrinkWrap: true,
              children: [
                if (widget.first) ...[
                  const PlasmaText('KAIROS NOVA',
                      style: TextStyle(fontSize: 38, fontWeight: FontWeight.w900, letterSpacing: 2))
                      .animate().fadeIn(duration: 600.ms).slideY(begin: 0.2),
                  const SizedBox(height: 6),
                  const Text('Veloce. Stabile. Senza limiti di canali.',
                      style: TextStyle(color: KairosColors.textDim, fontSize: 16)),
                  const SizedBox(height: 28),
                ] else
                  Row(children: [
                    IconButton(onPressed: () => context.pop(), icon: const Icon(Icons.arrow_back_rounded)),
                    Text('Aggiungi lista', style: Theme.of(context).textTheme.headlineMedium),
                  ]),
                GlassPanel(
                  padding: EdgeInsets.zero,
                  child: Column(children: [
                    TabBar(
                      controller: _tabs,
                      indicatorColor: KairosColors.cyan,
                      labelColor: KairosColors.cyan,
                      unselectedLabelColor: KairosColors.textDim,
                      tabs: const [Tab(text: 'URL M3U'), Tab(text: 'File'), Tab(text: 'Xtream')],
                      onTap: (_) => setState(() {}),
                    ),
                    Padding(
                      padding: const EdgeInsets.all(18),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        TextField(controller: _name, decoration: const InputDecoration(hintText: 'Nome lista (opzionale)')),
                        const SizedBox(height: 12),
                        if (_tabs.index == 0)
                          TextField(controller: _url, keyboardType: TextInputType.url,
                              decoration: const InputDecoration(hintText: 'http://server/get.php?… oppure .m3u/.m3u8')),
                        if (_tabs.index == 1)
                          OutlinedButton.icon(
                            onPressed: () async {
                              final r = await FilePicker.platform.pickFiles(type: FileType.any);
                              if (r != null && r.files.single.path != null) {
                                setState(() => _filePath = r.files.single.path);
                              }
                            },
                            icon: const Icon(Icons.folder_open_rounded),
                            label: Text(_filePath == null ? 'Scegli file .m3u' : _filePath!.split('/').last,
                                overflow: TextOverflow.ellipsis),
                          ),
                        if (_tabs.index == 2) ...[
                          TextField(controller: _host, keyboardType: TextInputType.url,
                              decoration: const InputDecoration(hintText: 'Server (http://host:porta)')),
                          const SizedBox(height: 12),
                          TextField(controller: _user, decoration: const InputDecoration(hintText: 'Username')),
                          const SizedBox(height: 12),
                          TextField(controller: _pass, obscureText: true, decoration: const InputDecoration(hintText: 'Password')),
                        ],
                        const SizedBox(height: 12),
                        TextField(controller: _epg, keyboardType: TextInputType.url,
                            decoration: const InputDecoration(hintText: 'URL EPG XMLTV (opzionale, anche .gz)')),
                        const SizedBox(height: 18),
                        if (_busy && _progress != null) _Progress(_progress!, fmt) else
                          FilledButton.icon(
                            onPressed: _start,
                            icon: const Icon(Icons.bolt_rounded),
                            label: const Text('Importa'),
                          ),
                      ]),
                    ),
                  ]),
                ),
                const SizedBox(height: 18),
                const Text(
                  'Le liste grandi (300.000+ voci) vengono analizzate in streaming e indicizzate su database: '
                  'l\'app resta fluida durante l\'import e la ricerca è istantanea.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: KairosColors.textMute, fontSize: 12.5),
                ),
              ],
            ),
          ),
        ),
      ]),
    );
  }
}

class _Progress extends StatelessWidget {
  const _Progress(this.p, this.fmt);
  final ImportProgress p;
  final NumberFormat fmt;

  @override
  Widget build(BuildContext context) {
    final mb = (p.bytesRead / 1048576).toStringAsFixed(1);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: KairosColors.cyan)),
        const SizedBox(width: 12),
        Expanded(child: Text(p.phase, style: const TextStyle(fontWeight: FontWeight.w600))),
      ]),
      const SizedBox(height: 10),
      ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: LinearProgressIndicator(
          value: p.fraction,
          minHeight: 6,
          backgroundColor: Colors.white12,
          valueColor: const AlwaysStoppedAnimation(KairosColors.cyan),
        ),
      ),
      const SizedBox(height: 8),
      Text('${fmt.format(p.parsed)} voci · $mb MB',
          style: const TextStyle(color: KairosColors.textDim, fontSize: 12)),
    ]);
  }
}
