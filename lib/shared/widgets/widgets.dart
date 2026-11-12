import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/device_tier.dart';
import '../../core/download/download_manager.dart';
import '../../core/images.dart';
import '../../core/models/models.dart';
import '../../core/panel/panel_service.dart';
import '../../core/providers.dart';
import '../../core/theme/kairos_theme.dart';

/// Logo canale con cache su disco, fallback a monogramma colorato.
class ChannelLogo extends StatelessWidget {
  const ChannelLogo(this.channel, {super.key, this.size = 48, this.radius = 12});
  final Channel channel;
  final double size;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final logo = channel.logo;
    final fallback = _Monogram(channel.name, size: size, radius: radius);
    if (logo == null || logo.isEmpty || !logo.startsWith('http')) return fallback;
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: NetImage(
        logo,
        width: size,
        height: size,
        fit: BoxFit.contain,
        decodeWidth: (size * 2).round(),
        fadeIn: const Duration(milliseconds: 150),
        placeholder: (_) => Container(color: KairosColors.surfaceHi),
        error: (_) => fallback,
      ),
    );
  }
}

/// Immagine di rete (loghi, locandine): cache su disco con tetto per classe ([NovaImageCache]), decodifica alla
/// misura mostrata ([decodeWidth] = pixel reali, mai l'originale) e locandine TMDB scaricate alla misura che serve
/// ([tmdbSized]); se quella misura non arriva si riprova una volta con il link originale, poi [error].
/// Sui dispositivi deboli niente dissolvenze (ogni immagine in dissolvenza è un livello in più per la GPU).
class NetImage extends StatelessWidget {
  const NetImage(
    this.url, {
    super.key,
    required this.decodeWidth,
    required this.error,
    this.width,
    this.height,
    this.fit,
    this.fadeIn = const Duration(milliseconds: 500),
    this.placeholder,
  });

  final String url;
  final int decodeWidth;
  final Widget Function(BuildContext context) error;
  final double? width;
  final double? height;
  final BoxFit? fit;
  final Duration fadeIn;
  final Widget Function(BuildContext context)? placeholder;

  @override
  Widget build(BuildContext context) {
    final sized = tmdbSized(url, decodeWidth, weak: DeviceTier.weak);
    if (sized == url) return _image(url, error);
    return _image(sized, (ctx) => _image(url, error));
  }

  Widget _image(String src, Widget Function(BuildContext context) onError) => CachedNetworkImage(
        imageUrl: src,
        cacheManager: NovaImageCache.instance,
        width: width,
        height: height,
        fit: fit,
        memCacheWidth: decodeWidth,
        fadeInDuration: DeviceTier.weak ? Duration.zero : fadeIn,
        fadeOutDuration: DeviceTier.weak ? Duration.zero : const Duration(milliseconds: 1000),
        placeholder: placeholder == null ? null : (ctx, __) => placeholder!(ctx),
        errorWidget: (ctx, __, ___) => onError(ctx),
      );
}

final RegExp _notInitial = RegExp(r'[^A-Za-z0-9 ]');

class _Monogram extends StatelessWidget {
  const _Monogram(this.name, {required this.size, required this.radius});
  final String name;
  final double size;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final hue = (name.hashCode % 360).toDouble();
    final c = HSLColor.fromAHSL(1, hue, 0.6, 0.45).toColor();
    final initials = name
        .replaceAll(_notInitial, '')
        .trim()
        .split(' ')
        .where((w) => w.isNotEmpty)
        .take(2)
        .map((w) => w[0].toUpperCase())
        .join();
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        gradient: LinearGradient(colors: [c, c.withOpacity(0.5)]),
      ),
      alignment: Alignment.center,
      child: Text(initials.isEmpty ? '•' : initials,
          style: TextStyle(
              fontSize: size * 0.36, fontWeight: FontWeight.w800, color: Colors.white)),
    );
  }
}

/// Riga canale per liste virtualizzate. Focus visibile per D-pad/TV.
class ChannelTile extends ConsumerWidget {
  const ChannelTile(this.channel, {super.key, this.showGroup = false, this.autofocus = false});
  final Channel channel;
  final bool showGroup;
  final bool autofocus;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final nn = ref.watch(nowNextProvider(channel.tvgId));
    return _Focusable(
      autofocus: autofocus,
      onTap: () => context.push('/play/${channel.id}'),
      onLongPress: () => showChannelMenu(context, ref, channel),
      builder: (focused) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: focused ? KairosColors.surfaceHi : Colors.transparent,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
              color: focused ? KairosColors.cyan.withOpacity(0.7) : Colors.transparent),
        ),
        child: Row(children: [
          if (channel.number != null)
            SizedBox(
              width: 44,
              child: Text('${channel.number}',
                  style: const TextStyle(
                      color: KairosColors.textMute,
                      fontWeight: FontWeight.w700,
                      fontFeatures: [FontFeature.tabularFigures()])),
            ),
          ChannelLogo(channel, size: 46),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(channel.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
              const SizedBox(height: 3),
              if (nn.now != null) ...[
                Text(nn.now!.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: KairosColors.textDim, fontSize: 12.5)),
                const SizedBox(height: 5),
                ProgressBar(nn.now!.progressAt(DateTime.now()), height: 2.5),
              ] else
                Text(showGroup ? channel.groupName : _typeLabel(channel.type),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: KairosColors.textMute, fontSize: 12)),
            ]),
          ),
          if (channel.isFavorite)
            const Padding(
              padding: EdgeInsets.only(left: 8),
              child: Icon(Icons.favorite, size: 16, color: KairosColors.magenta),
            ),
          if (channel.catchupDays > 0)
            const Padding(
              padding: EdgeInsets.only(left: 8),
              child: Icon(Icons.replay, size: 16, color: KairosColors.textDim),
            ),
        ]),
      ),
    );
  }
}

String _typeLabel(ChannelType t) => switch (t) {
      ChannelType.live => 'Live',
      ChannelType.movie => 'Film',
      ChannelType.series => 'Serie',
      ChannelType.radio => 'Radio',
    };

/// Card tipo "poster" per home e griglie.
class ChannelCard extends ConsumerWidget {
  const ChannelCard(this.channel, {super.key, this.width = 170, this.autofocus = false});
  final Channel channel;
  final double width;
  final bool autofocus;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final nn = ref.watch(nowNextProvider(channel.tvgId));
    final isPoster = channel.type != ChannelType.live && channel.type != ChannelType.radio;
    return _Focusable(
      autofocus: autofocus,
      onTap: () => context.push('/play/${channel.id}'),
      onLongPress: () => showChannelMenu(context, ref, channel),
      builder: (focused) => AnimatedScale(
        scale: focused ? 1.06 : 1,
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOutCubic,
        child: Container(
          width: width,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            boxShadow: focused
                ? [BoxShadow(color: KairosColors.cyan.withOpacity(0.35), blurRadius: 24, spreadRadius: -2)]
                : null,
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            AspectRatio(
              aspectRatio: isPoster ? 2 / 3 : 16 / 9,
              child: Container(
                decoration: BoxDecoration(
                  color: KairosColors.surface,
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(
                      color: focused ? KairosColors.cyan : KairosColors.line, width: focused ? 1.5 : 1),
                ),
                clipBehavior: Clip.antiAlias,
                child: Stack(fit: StackFit.expand, children: [
                  if (channel.logo != null && channel.logo!.startsWith('http'))
                    NetImage(
                      channel.logo!,
                      fit: isPoster ? BoxFit.cover : BoxFit.contain,
                      decodeWidth: (width * 2).round(),
                      error: (_) => Center(child: ChannelLogo(channel, size: 56)),
                    )
                  else
                    Center(child: ChannelLogo(channel, size: 56)),
                  if (!isPoster && nn.now != null)
                    Positioned(
                      left: 0, right: 0, bottom: 0,
                      child: ProgressBar(nn.now!.progressAt(DateTime.now()), height: 3, radius: 0),
                    ),
                  if (channel.isFavorite)
                    const Positioned(
                        top: 8, right: 8,
                        child: Icon(Icons.favorite, size: 16, color: KairosColors.magenta)),
                ]),
              ),
            ),
            const SizedBox(height: 8),
            Text(channel.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5)),
            if (nn.now != null)
              Text(nn.now!.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: KairosColors.textDim, fontSize: 11.5)),
          ]),
        ),
      ),
    );
  }
}

class ProgressBar extends StatelessWidget {
  const ProgressBar(this.value, {super.key, this.height = 3, this.radius = 2});
  final double value;
  final double height;
  final double radius;

  @override
  Widget build(BuildContext context) => ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: LinearProgressIndicator(
          value: value.clamp(0, 1),
          minHeight: height,
          backgroundColor: Colors.white.withOpacity(0.12),
          valueColor: const AlwaysStoppedAnimation(KairosColors.cyan),
        ),
      );
}

/// Wrapper focus+tap unificato per touch, mouse e telecomando.
class _Focusable extends StatefulWidget {
  const _Focusable({
    required this.builder,
    required this.onTap,
    this.onLongPress,
    this.autofocus = false,
  });
  final Widget Function(bool focused) builder;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final bool autofocus;

  @override
  State<_Focusable> createState() => _FocusableState();
}

class _FocusableState extends State<_Focusable> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return FocusableActionDetector(
      autofocus: widget.autofocus,
      onShowFocusHighlight: (f) => setState(() => _focused = f),
      onShowHoverHighlight: (f) => setState(() => _focused = f),
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) {
          widget.onTap();
          return null;
        }),
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        onLongPress: widget.onLongPress,
        child: widget.builder(_focused),
      ),
    );
  }
}

/// Menu contestuale canale (long-press / tasto menu).
void showChannelMenu(BuildContext context, WidgetRef ref, Channel c) {
  showModalBottomSheet(
    context: context,
    backgroundColor: Colors.transparent,
    builder: (ctx) => Padding(
      padding: const EdgeInsets.all(12),
      child: GlassPanel(
        opacity: 0.9,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Row(children: [
            ChannelLogo(c, size: 44),
            const SizedBox(width: 12),
            Expanded(
                child: Text(c.name,
                    maxLines: 2, style: Theme.of(ctx).textTheme.titleMedium)),
          ]),
          const SizedBox(height: 10),
          ListTile(
            leading: Icon(c.isFavorite ? Icons.favorite : Icons.favorite_border,
                color: KairosColors.magenta),
            title: Text(c.isFavorite ? 'Rimuovi dai preferiti' : 'Aggiungi ai preferiti'),
            onTap: () {
              ref.read(actionsProvider).toggleFavorite(c);
              Navigator.pop(ctx);
            },
          ),
          ListTile(
            leading: const Icon(Icons.play_arrow_rounded),
            title: const Text('Riproduci'),
            onTap: () {
              Navigator.pop(ctx);
              ctx.push('/play/${c.id}');
            },
          ),
          if (c.type == ChannelType.movie || c.type == ChannelType.series)
            ListTile(
              leading: const Icon(Icons.movie_outlined),
              title: const Text('Trailer'),
              onTap: () async {
                // lo cerca il pannello (TMDB, YouTube, Apple) e si vede dentro l'app
                final panel = ref.read(panelProvider);
                final messenger = ScaffoldMessenger.of(ctx);
                Navigator.pop(ctx);
                messenger.showSnackBar(const SnackBar(content: Text('Cerco il trailer…'), duration: Duration(seconds: 2)));
                final ok = await panel.openTrailer(c.name, c.type == ChannelType.series ? 'series' : 'movie');
                if (!ok) messenger.showSnackBar(SnackBar(content: Text('Nessun trailer trovato per ${c.name}')));
              },
            ),
          if (c.type == ChannelType.movie || c.type == ChannelType.series)
            Builder(builder: (_) {
              final dm = ref.read(downloadManagerProvider);
              final existing = ref.read(dbProvider).downloadForChannel(c.id);
              return ListTile(
                leading: Icon(existing == null ? Icons.download_rounded : Icons.download_done_rounded, color: KairosColors.lime),
                title: Text(existing == null
                    ? 'Scarica per guardare offline'
                    : existing.status == DownloadStatus.done ? 'Già scaricato' : 'Download in corso'),
                onTap: () async {
                  Navigator.pop(ctx);
                  if (existing != null) {
                    ctx.go('/downloads');
                    return;
                  }
                  await dm.enqueue(c);
                  if (ctx.mounted) {
                    ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
                      content: Text('Download avviato: ${c.name}'),
                      action: SnackBarAction(label: 'Vedi', onPressed: () => ctx.go('/downloads')),
                    ));
                  }
                },
              );
            }),
          ListTile(
            leading: const Icon(Icons.grid_view_rounded),
            title: const Text('Apri in Multiview'),
            onTap: () {
              Navigator.pop(ctx);
              ctx.push('/multiview?add=${c.id}');
            },
          ),
          ListTile(
            leading: const Icon(Icons.visibility_off_outlined),
            title: Text('Nascondi gruppo "${c.groupName}"'),
            onTap: () {
              ref.read(settingsProvider.notifier).update(
                  (s) => s.copyWith(hiddenGroups: {...s.hiddenGroups, c.groupName}));
              Navigator.pop(ctx);
            },
          ),
        ]),
      ),
    ),
  );
}

class SectionHeader extends StatelessWidget {
  const SectionHeader(this.title, {super.key, this.action, this.onAction});
  final String title;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 22, 20, 10),
        child: Row(children: [
          Text(title, style: Theme.of(context).textTheme.titleLarge),
          const Spacer(),
          if (action != null)
            TextButton(onPressed: onAction, child: Text(action!)),
        ]),
      );
}

class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.icon, required this.title, this.subtitle, this.action});
  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          // sui dispositivi deboli l'icona resta ferma: niente fotogrammi continui per un effetto (es. Cerca vuota)
          if (DeviceTier.weak)
            Icon(icon, size: 64, color: KairosColors.textMute)
          else
            Icon(icon, size: 64, color: KairosColors.textMute)
                .animate(onPlay: (c) => c.repeat(reverse: true))
                .scaleXY(end: 1.08, duration: 1800.ms),
          const SizedBox(height: 16),
          Text(title, style: Theme.of(context).textTheme.titleLarge),
          if (subtitle != null) ...[
            const SizedBox(height: 6),
            Text(subtitle!, textAlign: TextAlign.center,
                style: const TextStyle(color: KairosColors.textDim)),
          ],
          if (action != null) ...[const SizedBox(height: 20), action!],
        ]),
      );
}
