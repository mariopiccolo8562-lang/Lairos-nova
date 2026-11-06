import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../core/models/models.dart';
import '../../core/providers.dart';
import '../../core/theme/kairos_theme.dart';
import '../../shared/widgets/widgets.dart';

/// Multiview: fino a 4 canali insieme (sport!). Audio su un riquadro alla volta,
/// tap per cambiare audio, doppio tap per aprire a schermo intero.
class MultiviewScreen extends ConsumerStatefulWidget {
  const MultiviewScreen({super.key});
  @override
  ConsumerState<MultiviewScreen> createState() => _MultiviewScreenState();
}

class _MultiviewScreenState extends ConsumerState<MultiviewScreen> {
  final _slots = List<_Slot?>.filled(4, null);
  int _audio = 0;

  @override
  void initState() {
    final watching = ref.read(watchingProvider.notifier); // niente aggiornamenti in background durante la visione
    Future.microtask(() => watching.state++);
    super.initState();
    WakelockPlus.enable();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final add = GoRouterState.of(context).uri.queryParameters['add'];
      final id = int.tryParse(add ?? '');
      if (id != null) _assign(0, ref.read(dbProvider).channel(id));
    });
  }

  void _assign(int i, Channel? c) {
    if (c == null) return;
    _slots[i]?.dispose();
    final slot = _Slot(c);
    slot.player.setVolume(i == _audio ? 100 : 0);
    slot.player.open(Media(c.url));
    setState(() => _slots[i] = slot);
  }

  void _setAudio(int i) {
    setState(() => _audio = i);
    for (var k = 0; k < 4; k++) {
      _slots[k]?.player.setVolume(k == i ? 100 : 0);
    }
  }

  Future<void> _pick(int i) async {
    final favs = ref.read(favoritesProvider);
    final recent = ref.read(recentProvider);
    final choices = {...recent, ...favs}.toList();
    final c = await showModalBottomSheet<Channel>(
      context: context,
      backgroundColor: KairosColors.bgElevated,
      isScrollControlled: true,
      builder: (ctx) => SizedBox(
        height: MediaQuery.sizeOf(ctx).height * 0.7,
        child: Column(children: [
          const Padding(padding: EdgeInsets.all(14), child: Text('Scegli da recenti e preferiti', style: TextStyle(fontWeight: FontWeight.w700))),
          Expanded(
            child: choices.isEmpty
                ? const EmptyState(icon: Icons.star_border_rounded, title: 'Nessun recente o preferito')
                : ListView.builder(
                    itemCount: choices.length,
                    itemExtent: 64,
                    itemBuilder: (_, k) => ListTile(
                      leading: ChannelLogo(choices[k], size: 40),
                      title: Text(choices[k].name, maxLines: 1, overflow: TextOverflow.ellipsis),
                      onTap: () => Navigator.pop(ctx, choices[k]),
                    ),
                  ),
          ),
        ]),
      ),
    );
    if (c != null) _assign(i, c);
  }

  @override
  void dispose() {
    for (final s in _slots) {
      s?.dispose();
    }
    final watching = ref.read(watchingProvider.notifier);
    Future.microtask(() => watching.state--);
    WakelockPlus.disable();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final filled = _slots.where((s) => s != null).length;
    final cols = filled <= 1 ? 1 : 2;
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(children: [
          Row(children: [
            IconButton(onPressed: () => context.pop(), icon: const Icon(Icons.arrow_back_rounded)),
            const Text('Multiview', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 18)),
            const Spacer(),
            const Padding(
              padding: EdgeInsets.only(right: 12),
              child: Text('Tap = audio · Doppio tap = schermo intero', style: TextStyle(color: KairosColors.textMute, fontSize: 12)),
            ),
          ]),
          Expanded(
            child: GridView.count(
              crossAxisCount: cols,
              childAspectRatio: 16 / 9,
              physics: const NeverScrollableScrollPhysics(),
              padding: const EdgeInsets.all(6),
              mainAxisSpacing: 6,
              crossAxisSpacing: 6,
              children: [
                for (var i = 0; i < 4; i++)
                  if (_slots[i] != null || i == filled)
                    _Tile(
                      slot: _slots[i],
                      hasAudio: _audio == i,
                      onTap: () => _slots[i] == null ? _pick(i) : _setAudio(i),
                      onDouble: () => _slots[i] == null ? null : context.push('/play/${_slots[i]!.channel.id}'),
                      onRemove: () { _slots[i]?.dispose(); setState(() => _slots[i] = null); },
                    ),
              ],
            ),
          ),
        ]),
      ),
    );
  }
}

class _Slot {
  _Slot(this.channel) {
    player = Player(configuration: const PlayerConfiguration(bufferSize: 16 * 1024 * 1024));
    final n = player.platform;
    if (n is NativePlayer) {
      n.setProperty('hwdec', 'auto-safe');
      n.setProperty('cache-secs', '8');
      n.setProperty('stream-lavf-o', 'reconnect=1,reconnect_streamed=1,reconnect_delay_max=4');
    }
    controller = VideoController(player);
  }
  final Channel channel;
  late final Player player;
  late final VideoController controller;
  void dispose() => player.dispose();
}

class _Tile extends StatelessWidget {
  const _Tile({required this.slot, required this.hasAudio, required this.onTap, required this.onDouble, required this.onRemove});
  final _Slot? slot;
  final bool hasAudio;
  final VoidCallback onTap, onRemove;
  final VoidCallback? onDouble;

  @override
  Widget build(BuildContext context) {
    final s = slot;
    return GestureDetector(
      onTap: onTap,
      onDoubleTap: onDouble,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: hasAudio && s != null ? KairosColors.cyan : KairosColors.line, width: hasAudio ? 2 : 1),
          color: KairosColors.surface,
        ),
        clipBehavior: Clip.antiAlias,
        child: s == null
            ? const Center(child: Icon(Icons.add_rounded, size: 48, color: KairosColors.textMute))
            : Stack(fit: StackFit.expand, children: [
                Video(controller: s.controller, controls: NoVideoControls, fill: Colors.black),
                Positioned(
                  left: 8, top: 8,
                  child: Row(children: [
                    ChannelLogo(s.channel, size: 24, radius: 6),
                    const SizedBox(width: 6),
                    Text(s.channel.name, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, shadows: [Shadow(blurRadius: 6)])),
                    if (hasAudio) const Padding(padding: EdgeInsets.only(left: 6), child: Icon(Icons.volume_up_rounded, size: 16, color: KairosColors.cyan)),
                  ]),
                ),
                Positioned(right: 2, top: 2, child: IconButton(onPressed: onRemove, icon: const Icon(Icons.close_rounded, size: 18))),
              ]),
      ),
    );
  }
}
