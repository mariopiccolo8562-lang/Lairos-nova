import 'package:flutter_test/flutter_test.dart';
import 'package:kairos_nova/core/home_rules.dart';
import 'package:kairos_nova/core/models/models.dart';
import 'package:kairos_nova/core/panel/panel_client.dart';

void main() {
  test('Home dal pannello: nomi confrontati senza maiuscole, accenti e spazi doppi', () {
    expect(normalizeCategoryName('  Prime   VIDÉO  '), 'prime video');
    expect(normalizeCategoryName('Çinéma Française'), 'cinema francaise');
    expect(normalizeCategoryName('Cinéma'), 'cinema'); // accento già separato dalla lettera
    final rules = HomeRules.parse('Sport, Prime Video;\nNetflix,, ', 'adult, xxx, 18+');
    expect(rules.top, ['sport', 'prime video', 'netflix']);
    expect(rules.hide, ['adult', 'xxx', '18+']);
    expect(rules.topRank('IT | SKY SPORT HD'), 0);
    expect(rules.topRank('Netflix Adult'), -1); // nascosto vince su primo piano
    expect(rules.hidden('Film per ADULTI'), isTrue);
    expect(rules.hidden('Commedia'), isFalse);
    expect(HomeRules.parse('', ' , ').isEmpty, isTrue);
  });

  test('elenchi: prima i gruppi in primo piano (ordine delle voci), poi gli altri, in fondo i nascosti', () {
    ChannelGroup g(String name) => ChannelGroup(name: name, count: 1, type: ChannelType.live);
    final groups = [g('Cinema'), g('XXX Hot'), g('Netflix Serie'), g('Sport 1'), g('Documentari'), g('Sport 2'), g('Prime Video')];
    final ordered = HomeRules.parse('sport, prime video, netflix', 'xxx').order(groups);
    expect([for (final x in ordered) x.name], ['Sport 1', 'Sport 2', 'Prime Video', 'Netflix Serie', 'Cinema', 'Documentari', 'XXX Hot']);
    expect(identical(HomeRules.parse('', '').order(groups), groups), isTrue);
  });

  test('righe in primo piano: ordine delle voci, a parità diretta prima di film e serie, al massimo 10', () {
    final live = [const ChannelGroup(name: 'Intrattenimento', count: 1, type: ChannelType.live), const ChannelGroup(name: 'SKY SPORT', count: 1, type: ChannelType.live)];
    final movies = [const ChannelGroup(name: 'Netflix', count: 1, type: ChannelType.movie), const ChannelGroup(name: 'Sport docs', count: 1, type: ChannelType.movie)];
    final top = HomeRules.parse('netflix, sport', 'docs').pickTop([live, movies]);
    expect([for (final x in top) '${x.type?.name}:${x.name}'], ['movie:Netflix', 'live:SKY SPORT']);
    final many = [for (var i = 0; i < 15; i++) ChannelGroup(name: 'Sport $i', count: 1, type: ChannelType.live)];
    expect(HomeRules.parse('sport', '').pickTop([many]).length, HomeRules.maxTop);
  });

  test('permessi dal pannello: oggetto all\'apertura, JSON nel battito (chiave assente = consentito)', () {
    expect(PanelState.parsePerms({'resInd': false, 'lite': true}), {'resInd': false, 'lite': true});
    expect(PanelState.parsePerms('{"resInd":false}'), {'resInd': false});
    expect(PanelState.parsePerms(''), isEmpty);
    expect(PanelState.parsePerms('non json'), isEmpty);
    expect(PanelState.parse({'status': 'active', 'perms': {'resInd': false}}).perms['resInd'], isFalse);
  });
}
