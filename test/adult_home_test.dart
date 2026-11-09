import 'dart:convert';
import 'dart:io' as io;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kairos_nova/core/home_rules.dart';
import 'package:kairos_nova/core/models/models.dart';
import 'package:kairos_nova/core/providers.dart';

/// Adulti fuori dalla Home (contratto comune di tutte le app Kairos, 9 novembre 2026).
/// `adult_vectors.json` è la copia esatta di `vectors.json` del contratto: 94 esempi, stesso esito in ogni app.
void main() {
  group('Riconoscimento degli adulti (esempi del contratto)', () {
    final vectors = jsonDecode(io.File('test/adult_vectors.json').readAsStringSync()) as Map<String, dynamic>;
    List<String> examples(String key) => [for (final s in vectors[key] as List<dynamic>) s as String];
    final catTrue = examples('cat_true');
    final catFalse = examples('cat_false');
    final titleTrue = examples('title_true');
    final titleFalse = examples('title_false');

    test('ci sono tutti i 94 esempi', () {
      expect(catTrue.length + catFalse.length + titleTrue.length + titleFalse.length, 94);
    });

    test('categorie per adulti riconosciute', () {
      for (final s in catTrue) {
        expect(adultCat(s), isTrue, reason: 'categoria per adulti non riconosciuta: «$s»');
      }
    });

    test('categorie normali lasciate stare', () {
      for (final s in catFalse) {
        expect(adultCat(s), isFalse, reason: 'categoria presa per adulti per sbaglio: «$s»');
      }
    });

    test('titoli per adulti riconosciuti (solo parole forti)', () {
      for (final s in titleTrue) {
        expect(adultTitle(s), isTrue, reason: 'titolo per adulti non riconosciuto: «$s»');
      }
    });

    test('titoli normali lasciati stare', () {
      for (final s in titleFalse) {
        expect(adultTitle(s), isFalse, reason: 'titolo preso per adulti per sbaglio: «$s»');
      }
    });

    test('titoli: stesso esito con la normalizzazione completa (nomi non ASCII) e in maiuscolo', () {
      // l'accento combinante in coda rende il nome non ASCII (via completa) e la normalizzazione lo toglie
      for (final s in titleTrue) {
        expect(adultTitle('$ś'), isTrue, reason: '«$s» con un accento in coda');
        expect(adultTitle(s.toUpperCase()), isTrue, reason: '«$s» in maiuscolo');
      }
      for (final s in titleFalse) {
        expect(adultTitle('$ś'), isFalse, reason: '«$s» con un accento in coda');
        expect(adultTitle(s.toUpperCase()), isFalse, reason: '«$s» in maiuscolo');
      }
      expect(adultTitle('Pornô Star'), isTrue);
      expect(adultTitle('Éducation sexuelle'), isFalse);
      expect(adultTitle('  PLAYBOY\t\tTV  '), isTrue);
    });

    test('normalizzazione: larghezza piena, accenti, maiuscole e spazi', () {
      expect(adultNormalize('ＸＸＸ'), 'xxx');
      expect(adultNormalize('  Érotique   HD '), 'erotique hd');
      expect(adultNormalize('Ｆｉｌｍ　＋１８'), 'film +18');
      expect(adultCat('Ｆｉｌｍ　＋１８'), isTrue);
      expect(adultTitle('ＢＲＡＺＺＥＲＳ １'), isTrue);
      expect(adultCat('Adult Swim'), isFalse);
      expect(adultCat('ADULT SWIM + XXX'), isTrue); // «adult swim» tolto, resta «xxx»
      expect(adultCat('Per adulti +18'), isTrue);
    });

    test('rc «adult»: filtro attivo se non è «on», anche assente o vuoto', () {
      expect(adultHiddenFromHome(null), isTrue);
      expect(adultHiddenFromHome(''), isTrue);
      expect(adultHiddenFromHome('off'), isTrue);
      expect(adultHiddenFromHome('on'), isFalse);
    });
  });

  group('Regole della Home con e senza «adult»', () {
    Channel ch(int id, String name, String group, {ChannelType type = ChannelType.live}) =>
        Channel(id: id, playlistId: 1, name: name, url: 'http://srv/$id', groupName: group, type: type);
    ChannelGroup g(String name, [ChannelType type = ChannelType.live]) => ChannelGroup(name: name, count: 1, type: type);

    test('senza regole e con «adult» = «on»: tutto come prima', () {
      final on = HomeRules.parse('', '');
      expect(on.isEmpty, isTrue);
      expect(on.hideAdult, isFalse);
      expect(on.hidden('Per adulti +18'), isFalse);
      final groups = [g('Cinema'), g('+18')];
      expect(identical(on.order(groups), groups), isTrue);
      final row = [ch(1, 'Brazzers TV', 'Intrattenimento'), ch(2, 'Canale', '+18')];
      expect(identical(on.homeItems(row), row), isTrue);
      expect(on.blocked(row.first), isFalse);
      expect(on.hero(row, const []), same(row.first));
      expect(on.heroFromRows(row, const []), isFalse);
    });

    test('adulti fuori: i gruppi per adulti contano come nascosti e vanno in fondo agli elenchi', () {
      final rules = HomeRules.parse('', '', hideAdult: true);
      expect(rules.isEmpty, isFalse);
      expect(rules.hidden('Per adulti +18'), isTrue);
      expect(rules.hidden('ＸＸＸ'), isTrue);
      expect(rules.hidden('Adult Swim'), isFalse);
      expect(rules.hidden('Intrattenimento'), isFalse);
      final groups = [g('Cinema'), g('+18'), g('Sport'), g('Film erotici'), g('Kids')];
      expect([for (final x in rules.order(groups)) x.name], ['Cinema', 'Sport', 'Kids', '+18', 'Film erotici']);
      // righe in primo piano: mai un gruppo per adulti, anche se lo schema lo prende
      final live = [g('Per adulti +18'), g('Intrattenimento')];
      expect([for (final x in HomeRules.parse('adulti, intratt', '', hideAdult: true).pickTop([live])) x.name],
          ['Intrattenimento']);
      expect([for (final x in HomeRules.parse('adulti, intratt', '').pickTop([live])) x.name],
          ['Per adulti +18', 'Intrattenimento']); // «on»: come prima
      // la lista «home.hide» continua a valere insieme al riconoscimento
      final both = HomeRules.parse('', 'sport', hideAdult: true);
      expect(both.hidden('Sport'), isTrue);
      expect(both.hidden('Hot Club'), isTrue);
    });

    test('righe della Home: niente canali, film e serie per adulti', () {
      final rules = HomeRules.parse('', 'horror', hideAdult: true);
      final row = [
        ch(1, 'Rai 1', 'Intrattenimento'),
        ch(2, 'Brazzers TV', 'Intrattenimento'), // titolo per adulti in un gruppo normale
        ch(3, 'Canale notte', 'Per adulti +18'), // gruppo per adulti
        ch(4, 'Paura', 'Horror', type: ChannelType.movie), // gruppo nascosto dalla lista «home.hide»
        ch(5, 'Sex Education', 'Serie TV', type: ChannelType.series), // resta
        ch(6, 'Sexy Beast', 'Commedia', type: ChannelType.movie), // resta
        ch(7, 'Film 18+', 'Azione', type: ChannelType.movie), // titolo per adulti
        ch(8, 'Notte', 'ＸＸＸ'), // gruppo per adulti a larghezza piena
      ];
      expect([for (final c in rules.homeItems(row)) c.id], [1, 5, 6]);
      final clean = [row[0], row[4]];
      expect(identical(rules.homeItems(clean), clean), isTrue);
      expect(rules.blocked(row[1]), isTrue);
      // le righe si rileggono dal database (oggetti nuovi): stesso esito, già calcolato per quel nome
      expect(rules.blocked(ch(20, 'Brazzers TV', 'Intrattenimento')), isTrue);
      expect(rules.blocked(ch(21, 'Rai 1', 'Intrattenimento')), isFalse);
    });

    test('titolo in evidenza: mai per adulti; se da riprendere c\'erano solo canali per adulti si sceglie fra gli altri', () {
      final rules = HomeRules.parse('', '', hideAdult: true);
      final adult = ch(1, 'Canale notte', 'Per adulti +18');
      final rai = ch(2, 'Rai 1', 'Intrattenimento');
      final film = ch(3, 'Pianeta', 'Documentari', type: ChannelType.movie);
      expect(rules.hero([adult, rai], [film]), same(rai));
      expect(rules.hero([adult], [film]), same(film));
      expect(rules.hero([adult], const []), isNull);
      expect(rules.heroFromRows([adult], const []), isTrue);
      expect(rules.heroFromRows([adult, rai], const []), isFalse);
      expect(rules.heroFromRows(const [], const []), isFalse); // niente da riprendere: «Benvenuto» come prima
      final on = HomeRules.parse('', '');
      expect(on.hero([adult, rai], const []), same(adult)); // «on»: come prima
      expect(on.heroFromRows([adult], const []), isFalse);
      expect(HomeRules.parse('', 'adulti').hero([adult, rai], const []), same(rai)); // «home.hide» come prima
    });

    test('provider della Home: righe senza adulti; con «on» le stesse liste di prima', () {
      final recent = [ch(1, 'Canale notte', 'Per adulti +18'), ch(2, 'Rai 1', 'Intrattenimento')];
      final favs = [ch(3, 'XXX Private', 'Intrattenimento'), ch(4, 'Pianeta', 'Documentari', type: ChannelType.movie)];
      ProviderContainer make(HomeRules rules) => ProviderContainer(overrides: [
            homeRulesProvider.overrideWithValue(rules),
            recentProvider.overrideWithValue(recent),
            favoritesProvider.overrideWithValue(favs),
          ]);
      final off = make(HomeRules.parse('', '', hideAdult: true));
      addTearDown(off.dispose);
      expect([for (final c in off.read(homeRecentProvider)) c.id], [2]);
      expect([for (final c in off.read(homeFavoritesProvider)) c.id], [4]);
      final on = make(HomeRules.parse('', ''));
      addTearDown(on.dispose);
      expect(identical(on.read(homeRecentProvider), recent), isTrue);
      expect(identical(on.read(homeFavoritesProvider), favs), isTrue);
    });
  });
}
