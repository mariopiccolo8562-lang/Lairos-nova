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

/// Home decisa dal fornitore (Controllo remoto del pannello): gruppi in primo piano (rc «home.top») e nascosti
/// dalla Home (rc «home.hide»). Ogni voce è un nome o una parte di nome; maiuscole, accenti e spazi doppi non
/// contano. Un gruppo nascosto non va mai in primo piano (come in Kairos Pro).
class HomeRules {
  HomeRules._(this.top, this.hide);

  factory HomeRules.parse(String top, String hide) => HomeRules._(_split(top), _split(hide));

  /// Al massimo tante righe in primo piano nella Home.
  static const int maxTop = 10;

  /// Schemi normalizzati, nell'ordine scelto dal fornitore.
  final List<String> top;
  final List<String> hide;

  /// Risultato per nome di gruppo: (posizione dello schema in primo piano o -1, nascosto).
  final Map<String, (int, bool)> _memo = <String, (int, bool)>{};

  static List<String> _split(String value) =>
      [for (final part in value.split(_separators)) normalizeCategoryName(part)]..removeWhere((p) => p.isEmpty);

  bool get isEmpty => top.isEmpty && hide.isEmpty;

  (int, bool) _match(String name) {
    final known = _memo[name];
    if (known != null) return known;
    final n = normalizeCategoryName(name);
    final isHidden = hide.any(n.contains);
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
  bool hidden(String groupName) => hide.isNotEmpty && _match(groupName).$2;

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
}

/// Regole della Home in uso: si ricalcolano solo quando il pannello cambia «home.top» o «home.hide».
final homeRulesProvider = Provider<HomeRules>((ref) {
  final top = ref.watch(panelProvider.select((p) => p.remoteConfig['home.top'] ?? ''));
  final hide = ref.watch(panelProvider.select((p) => p.remoteConfig['home.hide'] ?? ''));
  return HomeRules.parse(top, hide);
});

/// Gruppi per gli elenchi (Live TV, Film, Serie, Guida): prima quelli in primo piano, in fondo i nascosti.
final orderedGroupsProvider = Provider.family<List<ChannelGroup>, ChannelType>((ref, type) {
  return ref.watch(homeRulesProvider).order(ref.watch(groupsProvider(type)));
});
