import 'package:flutter_test/flutter_test.dart';
import 'package:kairos_nova/core/dns_badge.dart';

/// Lucchetto del DNS cifrato accanto alla «K»: quando c'è, di che colore, con quale frase.
void main() {
  test('senza la voce del pannello non c\'è niente', () {
    expect(DnsBadge.state(false, 'on'), '');
    expect(DnsBadge.state(false, ''), '');
    expect(DnsBadge.text(''), '');
  });

  test('stato del servizio', () {
    expect(DnsBadge.state(true, 'on'), 'on');
    expect(DnsBadge.state(true, 'denied'), 'denied');
    expect(DnsBadge.state(true, ''), 'off');
    expect(DnsBadge.on('on'), isTrue);
    for (final s in ['asking', 'denied', 'error', 'other']) {
      expect(DnsBadge.warn(s), isTrue, reason: s);
      expect(DnsBadge.on(s), isFalse, reason: s);
    }
    expect(DnsBadge.warn('off'), isFalse);
    expect(DnsBadge.on('off'), isFalse);
  });

  test('colori diversi per attivo, attenzione e avvio', () {
    expect({DnsBadge.color('on'), DnsBadge.color('denied'), DnsBadge.color('off')}.length, 3);
  });

  test('ogni stato ha la sua frase', () {
    for (final s in ['on', 'asking', 'denied', 'error', 'other', 'off']) {
      expect(DnsBadge.text(s), startsWith('DNS cifrato'), reason: s);
    }
  });
}
