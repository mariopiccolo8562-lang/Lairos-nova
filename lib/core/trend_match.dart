/// Titolo della classifica settimanale del pannello (/api/player/trending): titolo e anno, se c'è.
class TrendTitle {
  const TrendTitle(this.title, this.year);
  final String title;
  final int? year;
}

/// Classifica dei titoli di tendenza (13 novembre 2026): la stessa che il pannello dà a Kairos Pro, STB, Smarters,
/// Ultimate e alle altre app. Qui si legge la risposta e si trovano, nell'ordine della classifica, i titoli che la
/// linea ha davvero. Logica pura: la provano i test (test/trend_match_test.dart).
class TrendList {
  const TrendList(this.movies, this.series);
  final List<TrendTitle> movies;
  final List<TrendTitle> series;

  static const empty = TrendList(<TrendTitle>[], <TrendTitle>[]);

  bool get isEmpty => movies.isEmpty && series.isEmpty;

  /// Risposta del pannello: {"movies": [{"t": "...", "y": 2026}], "series": [...]}. Null se non è una classifica.
  static TrendList? parse(Object? json) {
    if (json is! Map || json['movies'] is! List) return null;
    List<TrendTitle> titles(Object? raw) {
      if (raw is! List) return const <TrendTitle>[];
      final out = <TrendTitle>[];
      for (final x in raw) {
        if (x is! Map) continue;
        final t = (x['t'] ?? '').toString().trim();
        if (t.isEmpty) continue;
        final y = x['y'];
        final year = y is num ? y.toInt() : int.tryParse('${y ?? ''}');
        out.add(TrendTitle(t, year != null && year > 0 ? year : null));
      }
      return out;
    }

    return TrendList(titles(json['movies']), titles(json['series']));
  }
}

final RegExp _leading = RegExp(r'^(?:(?:\|\s*IT\s*\||IT\s*[-|:]|(?:4K|UHD|FHD|HD)\s*\|)\s*)+', caseSensitive: false);
final RegExp _year = RegExp(r'\s*\(\d{4}\)\s*$');
final RegExp _quality = RegExp(r'\b(?:4K|UHD|FHD|HD|ITA|SUB\s+ITA)\b', caseSensitive: false);
final RegExp _punct = RegExp(r'[^a-z0-9]+');
final RegExp _spaces = RegExp(r'\s+');
const Map<String, String> _accents = {
  'à': 'a', 'á': 'a', 'â': 'a', 'ã': 'a', 'ä': 'a', 'å': 'a',
  'è': 'e', 'é': 'e', 'ê': 'e', 'ë': 'e',
  'ì': 'i', 'í': 'i', 'î': 'i', 'ï': 'i',
  'ò': 'o', 'ó': 'o', 'ô': 'o', 'õ': 'o', 'ö': 'o',
  'ù': 'u', 'ú': 'u', 'û': 'u', 'ü': 'u',
  'ñ': 'n', 'ç': 'c',
};

/// Titolo ridotto all'essenziale: senza «IT |», qualità, anno tra parentesi, accenti e punteggiatura.
String normTitle(String value) {
  var s = value.trim().replaceFirst(_leading, '');
  s = s.replaceAll(_quality, ' ').replaceFirst(_year, '').toLowerCase();
  // accenti solo se ce ne sono (con decine di migliaia di titoli conta)
  if (s.codeUnits.any((c) => c > 127)) {
    final b = StringBuffer();
    for (final ch in s.split('')) {
      b.write(_accents[ch] ?? ch);
    }
    s = b.toString();
  }
  return s.replaceAll(_punct, ' ').trim().replaceAll(_spaces, ' ');
}

/// Stesso titolo e, se si sanno tutti e due, anno uguale o vicino (±1).
bool titleMatches(String localName, int? localYear, String trendTitle, int? trendYear) {
  final local = normTitle(localName);
  if (local.isEmpty || local != normTitle(trendTitle)) return false;
  return localYear == null || trendYear == null || (localYear - trendYear).abs() <= 1;
}

final RegExp _yearInName = RegExp(r'\((\d{4})\)\s*$');

/// Anno scritto in fondo al nome, come «Dune (2021)»; null se non c'è.
int? yearFromName(String name) => int.tryParse(_yearInName.firstMatch(name.trim())?.group(1) ?? '');
