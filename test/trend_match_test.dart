import 'package:flutter_test/flutter_test.dart';
import 'package:kairos_nova/core/trend_match.dart';

void main() {
  test('legge la classifica del pannello', () {
    final t = TrendList.parse(<String, dynamic>{
      'movies': [
        {'t': 'Interstellar', 'y': 2014},
        {'t': ' '},
      ],
      'series': [
        {'t': 'Dark'},
      ],
    })!;
    expect(t.movies.single.title, 'Interstellar');
    expect(t.series.single.year, isNull);
    expect(TrendList.parse(<String, dynamic>{}), isNull);
  });

  test('titoli e anni', () {
    expect(normTitle('IT | Il Padrino (1972)'), 'il padrino');
    expect(titleMatches('Dune (2021)', yearFromName('Dune (2021)'), 'Dune', 2021), isTrue);
    expect(titleMatches('Dune (1984)', yearFromName('Dune (1984)'), 'Dune', 2021), isFalse);
    expect(yearFromName('Dune'), isNull);
  });
}
