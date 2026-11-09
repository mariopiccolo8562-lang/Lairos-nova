import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'models/models.dart';
import 'panel/panel_service.dart';
import 'providers.dart';

/// Nome di gruppo pronto per il confronto: minuscolo, senza accenti, spazi multipli ridotti a uno
/// (come Kairos Pro: NFD e segni diacritici tolti).
String normalizeCategoryName(String value) {
  final out = StringBuffer();
  for (final rune in value.toLowerCase().runes) {
    if (rune >= 0x300 && rune <= 0x36f) continue; // segni diacritici già separati dalla lettera
    final plain = _plainLetters[rune];
    if (plain != null) {
      out.write(plain);
    } else {
      out.writeCharCode(rune);
    }
  }
  return out.toString().replaceAll(_spaces, ' ').trim();
}

final RegExp _spaces = RegExp(r'\s+');
final RegExp _separators = RegExp(r'[,;\n]+');

/// Lettere accentate (minuscole) → lettera senza accento: quelle che la forma NFD separa in lettera + segno.
final Map<int, String> _plainLetters = () {
  const groups = <String, String>{
    'a': 'àáâãäåāăą',
    'c': 'çćĉċč',
    'd': 'ď',
    'e': 'èéêëēĕėęě',
    'g': 'ĝğġģ',
    'h': 'ĥ',
    'i': 'ìíîïĩīĭį',
    'j': 'ĵ',
    'k': 'ķ',
    'l': 'ĺļľ',
    'n': 'ñńņň',
    'o': 'òóôõöōŏő',
    'r': 'ŕŗř',
    's': 'śŝşšș',
    't': 'ţťț',
    'u': 'ùúûüũūŭůűų',
    'w': 'ŵ',
    'y': 'ýÿŷ',
    'z': 'źżž',
  };
  final map = <int, String>{};
  for (final group in groups.entries) {
    for (final rune in group.value.runes) {
      map[rune] = group.key;
    }
  }
  return map;
}();

// ---------------------------------------------------------------------------
// Adulti fuori dalla Home: riconoscimento comune a tutte le app Kairos (contratto del 9 novembre 2026).

/// Il pannello vuole gli adulti fuori dalla Home: rc «adult» diverso da «on», quindi anche assente o vuoto
/// (anche senza collegamento al pannello).
bool adultHiddenFromHome(Object? rcValue) => rcValue?.toString() != 'on';

/// Nome pronto per il riconoscimento degli adulti. In Dart la forma NFKD non c'è: le lettere a larghezza piena
/// (U+FF01–U+FF5E, «ＸＸＸ») diventano quelle normali sottraendo 0xFEE0, poi come [normalizeCategoryName]
/// (minuscolo, senza accenti, spazi multipli ridotti a uno e tolti ai bordi).
String adultNormalize(String value) {
  final out = StringBuffer();
  for (final rune in value.runes) {
    out.writeCharCode(rune >= 0xFF01 && rune <= 0xFF5E ? rune - 0xFEE0 : rune);
  }
  return normalizeCategoryName(out.toString());
}

// Le due espressioni del contratto, identiche in tutte le app (stringhe «raw»: in una stringa normale «\b»
// sarebbe il carattere di backspace). Si provano sul nome già normalizzato, quindi senza maiuscole.
final RegExp _adultCategory = RegExp(
    r'(\bxxx\b|adult|\bporn|erotic|erotik|erotis|erotiq|hentai|\b18\s*\+|\+\s*18\b|\bv\.?\s*m\.?\s*18\b|\bsexy?\b|\bhot\s*club\b|playboy|brazzers|hustler|dorcel|only\s*fans|red\s*light|\bx[\s-]?rated\b|\bnsfw\b|\bmilf\b|private\s*tv|vietato ai minori)');
const String _adultTitlePattern =
    r'(\bxxx\b|\bporn|hentai|brazzers|playboy\s*tv|hustler\s*tv|dorcel|only\s*fans|\b18\s*\+|\+\s*18\b)';
final RegExp _adultTitle = RegExp(_adultTitlePattern);
// La stessa senza maiuscole, per i nomi tutti ASCII: lì normalizzare vuol dire solo passare in minuscolo (gli spazi
// multipli e ai bordi non cambiano l'esito), quindi stesso risultato senza creare testi nuovi per ogni titolo.
final RegExp _adultTitleAscii = RegExp(_adultTitlePattern, caseSensitive: false);
final RegExp _adultSwim = RegExp(r'adult\s*swim');

bool _ascii(String s) {
  for (var i = 0; i < s.length; i++) {
    if (s.codeUnitAt(i) > 0x7F) return false;
  }
  return true;
}

/// Gruppo (categoria) per adulti: il nome normalizzato, tolto «adult swim», contiene una parola per adulti.
bool adultCat(String name) => _adultCategory.hasMatch(adultNormalize(name).replaceAll(_adultSwim, ''));

/// Titolo o canale per adulti: solo le parole forti (un film come «Sex Education» resta dov'è).
bool adultTitle(String name) =>
    _ascii(name) ? _adultTitleAscii.hasMatch(name) : _adultTitle.hasMatch(adultNormalize(name));

/// Esito di [adultTitle] per nome, calcolato una volta sola: le righe della Home si rileggono dal database (oggetti
/// nuovi a ogni lettura, anche a ogni canale che parte durante la visione), i nomi restano gli stessi.
final Map<String, bool> _strongTitle = <String, bool>{};

bool _titleOf(Channel c) {
  final known = _strongTitle[c.name];
  if (known != null) return known;
  if (_strongTitle.length > 5000) _strongTitle.clear();
  return _strongTitle[c.name] = adultTitle(c.name);
}

/// Home decisa dal fornitore (Controllo remoto del pannello): gruppi in primo piano (rc «home.top») e nascosti
/// dalla Home (rc «home.hide»). Ogni voce è un nome o una parte di nome; maiuscole, accenti e spazi doppi non
/// contano. Un gruppo nascosto non va mai in primo piano (come in Kairos Pro).
///
/// Con [hideAdult] (rc «adult» diverso da «on») i gruppi per adulti ([adultCat]) contano come nascosti e nelle
/// righe della Home non entra nessun canale, film o serie per adulti ([blocked]).
class HomeRules {
  HomeRules._(this.top, this.hide, this.hideAdult);

  factory HomeRules.parse(String top, String hide, {bool hideAdult = false}) =>
      HomeRules._(_split(top), _split(hide), hideAdult);

  /// Al massimo tante righe in primo piano nella Home.
  static const int maxTop = 10;

  /// Schemi normalizzati, nell'ordine scelto dal fornitore.
  final List<String> top;
  final List<String> hide;

  /// Adulti fuori dalla Home: gruppi per adulti nascosti e nessun elemento per adulti nelle righe.
  final bool hideAdult;

  /// Risultato per nome di gruppo: (posizione dello schema in primo piano o -1, nascosto).
  final Map<String, (int, bool)> _memo = <String, (int, bool)>{};

  static List<String> _split(String value) =>
      [for (final part in value.split(_separators)) normalizeCategoryName(part)]..removeWhere((p) => p.isEmpty);

  bool get isEmpty => top.isEmpty && hide.isEmpty && !hideAdult;

  (int, bool) _match(String name) {
    final known = _memo[name];
    if (known != null) return known;
    final n = normalizeCategoryName(name);
    // con gli adulti fuori dalla Home un gruppo per adulti conta come nascosto (una volta per nome)
    final isHidden = hide.any(n.contains) || (hideAdult && adultCat(name));
    var rank = -1;
    if (!isHidden) {
      for (var i = 0; i < top.length; i++) {
        if (n.contains(top[i])) {
          rank = i;
          break;
        }
      }
    }
    if (_memo.length > 5000) _memo.clear();
    return _memo[name] = (rank, isHidden);
  }

  /// Il gruppo non compare nella Home (negli elenchi va in fondo).
  bool hidden(String groupName) => (hide.isNotEmpty || hideAdult) && _match(groupName).$2;

  /// Posizione del primo schema in primo piano che prende il gruppo (-1 = nessuno).
  int topRank(String groupName) => top.isEmpty ? -1 : _match(groupName).$1;

  /// Elenchi e menu dei gruppi: prima quelli in primo piano (nell'ordine degli schemi, a parità nell'ordine di
  /// prima), poi gli altri come sempre, in fondo i nascosti (restano raggiungibili).
  List<ChannelGroup> order(List<ChannelGroup> groups) {
    if (isEmpty) return groups;
    final first = <(int, int, ChannelGroup)>[];
    final middle = <ChannelGroup>[];
    final last = <ChannelGroup>[];
    for (var i = 0; i < groups.length; i++) {
      final g = groups[i];
      final (rank, isHidden) = _match(g.name);
      if (isHidden) {
        last.add(g);
      } else if (rank >= 0) {
        first.add((rank, i, g));
      } else {
        middle.add(g);
      }
    }
    if (first.isEmpty && last.isEmpty) return groups;
    first.sort((a, b) => a.$1 != b.$1 ? a.$1.compareTo(b.$1) : a.$2.compareTo(b.$2));
    return [for (final x in first) x.$3, ...middle, ...last];
  }

  /// Righe in primo piano della Home: gruppi di TV in diretta, film e serie presi dagli schemi (al massimo
  /// [maxTop]), nell'ordine degli schemi; a parità prima la diretta, poi film e serie, nell'ordine di sempre.
  List<ChannelGroup> pickTop(List<List<ChannelGroup>> lists) {
    if (top.isEmpty) return const [];
    final picks = <(int, int, ChannelGroup)>[];
    var n = 0;
    for (final list in lists) {
      for (final g in list) {
        final rank = topRank(g.name);
        if (rank >= 0) picks.add((rank, n, g));
        n++;
      }
    }
    picks.sort((a, b) => a.$1 != b.$1 ? a.$1.compareTo(b.$1) : a.$2.compareTo(b.$2));
    return [for (final p in picks.take(maxTop)) p.$3];
  }

  /// Con gli adulti fuori dalla Home: il canale (o film, serie) non entra in nessuna riga della Home, perché il suo
  /// gruppo è per adulti o nascosto, oppure il suo nome è un titolo per adulti. Senza filtro: mai.
  /// Il gruppo si valuta una volta per nome, il titolo una volta per elemento (solo per quelli delle righe).
  bool blocked(Channel c) => hideAdult && (hidden(c.groupName) || _titleOf(c));

  /// Una riga della Home senza gli elementi per adulti (senza filtro, o se non ce ne sono, la stessa lista).
  List<Channel> homeItems(List<Channel> items) {
    if (!hideAdult) return items;
    for (var i = 0; i < items.length; i++) {
      if (blocked(items[i])) return [for (final c in items) if (!blocked(c)) c];
    }
    return items;
  }

  /// Canale in evidenza nella Home («Riprendi»): il primo visto di recente, poi il primo preferito, che non è di un
  /// gruppo nascosto né, con gli adulti fuori dalla Home, per adulti.
  Channel? hero(List<Channel> recent, List<Channel> favorites) {
    for (final list in [recent, favorites]) {
      for (final c in list) {
        if (!hidden(c.groupName) && !blocked(c)) return c;
      }
    }
    return null;
  }

  /// Con gli adulti fuori dalla Home, se fra i recenti e i preferiti c'erano solo canali da togliere il riquadro in
  /// evidenza sceglie fra gli altri titoli della Home invece di restare senza titolo.
  bool heroFromRows(List<Channel> recent, List<Channel> favorites) =>
      hideAdult && (recent.isNotEmpty || favorites.isNotEmpty) && hero(recent, favorites) == null;
}

/// Regole della Home in uso: si ricalcolano solo quando il pannello cambia «home.top», «home.hide» o «adult».
final homeRulesProvider = Provider<HomeRules>((ref) {
  final top = ref.watch(panelProvider.select((p) => p.remoteConfig['home.top'] ?? ''));
  final hide = ref.watch(panelProvider.select((p) => p.remoteConfig['home.hide'] ?? ''));
  final hideAdult = ref.watch(panelProvider.select((p) => adultHiddenFromHome(p.remoteConfig['adult'])));
  return HomeRules.parse(top, hide, hideAdult: hideAdult);
});

// Righe della Home senza gli elementi per adulti (con il filtro attivo): si ricalcolano solo quando cambia la riga
// o una regola, non a ogni ricostruzione della Home (che avviene anche sotto il lettore, a ogni canale che parte).

/// «Continua a guardare» della Home.
final homeRecentProvider = Provider<List<Channel>>((ref) => ref.watch(homeRulesProvider).homeItems(ref.watch(recentProvider)));

/// «Preferiti» della Home.
final homeFavoritesProvider =
    Provider<List<Channel>>((ref) => ref.watch(homeRulesProvider).homeItems(ref.watch(favoritesProvider)));

/// Prime voci di un gruppo per le righe della Home ([groupPreviewProvider]).
final homeGroupPreviewProvider = Provider.autoDispose.family<List<Channel>, ChannelQuery>(
    (ref, q) => ref.watch(homeRulesProvider).homeItems(ref.watch(groupPreviewProvider(q))));

/// Gruppi per gli elenchi (Live TV, Film, Serie, Guida): prima quelli in primo piano, in fondo i nascosti.
final orderedGroupsProvider = Provider.family<List<ChannelGroup>, ChannelType>((ref, type) {
  return ref.watch(homeRulesProvider).order(ref.watch(groupsProvider(type)));
});
