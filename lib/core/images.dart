import 'package:flutter_cache_manager/flutter_cache_manager.dart';

import 'device_tier.dart';

/// Cache su disco di locandine e loghi: la stessa di prima (cartella cache dell'app, che Android svuota da sola se
/// manca spazio; stesso archivio, quindi nessun nuovo download dopo l'aggiornamento), ma con un tetto per classe.
/// La libreria conta i file, non i byte: 1200 file sui dispositivi deboli e 2000 sugli altri stanno entro ~150 MB e
/// ~250 MB anche con locandine da ~120 KB (con le misure TMDB ridotte di solito molto meno). Prima il tetto era di
/// 200 file: con una Home da centinaia di locandine si riscaricavano di continuo. Le immagini viste nelle ultime
/// 24 ore la libreria non le toglie comunque; quelle non usate da 30 giorni sì.
class NovaImageCache extends CacheManager with ImageCacheManager {
  NovaImageCache._()
      : super(Config(
          DefaultCacheManager.key,
          stalePeriod: const Duration(days: 30),
          maxNrOfCacheObjects: DeviceTier.weak ? 1200 : 2000,
        ));

  /// L'unica cache delle immagini dell'app (due gestori sullo stesso archivio non vanno bene).
  static final NovaImageCache instance = NovaImageCache._();
}

final RegExp _tmdbRe = RegExp(r'^(https?://image\.tmdb\.org/t/p/)([^/]+)(/.+)$', caseSensitive: false);
final RegExp _tmdbW = RegExp(r'^w(\d+)');

/// Locandine TMDB (image.tmdb.org/t/p/<misura>/…) alla misura che serve davvero invece di «original» o w500/w600
/// (4-10 volte i pixel): w185 per le viste fino a 185 px reali e sui dispositivi deboli, w342 per le altre.
/// [decodeWidth] = larghezza in pixel reali della vista. Una misura già più piccola resta com'è; gli altri
/// indirizzi non si toccano. Se la misura piccola non arriva, chi la usa riprova con il link originale.
String tmdbSized(String url, int decodeWidth, {bool weak = false}) {
  final m = _tmdbRe.firstMatch(url);
  if (m == null) return url;
  final size = m.group(2)!.toLowerCase();
  final target = weak || decodeWidth <= 185 ? 185 : 342;
  final w = _tmdbW.firstMatch(size);
  final known = w == null ? null : int.tryParse(w.group(1)!);
  // «original», «h632» e simili: più grandi (o ignote) → si riduce; «w92», «w154»… ≤ della misura scelta → invariate
  if (known != null && known <= target) return url;
  return '${m.group(1)}w$target${m.group(3)}';
}
