import 'dart:io' as io;

import 'package:flutter_test/flutter_test.dart';
import 'package:kairos_nova/core/panel/remote_quiet.dart';

void main() {
  group('Controlli a distanza senza avvisi', () {
    test('reset del PIN nei menu: si chiede subito il nuovo PIN, niente in attesa', () {
      final p = PinAsk();
      expect(p.onReset(watching: false), isTrue);
      expect(p.pending, isFalse);
      expect(p.onViewEnd(), isFalse);
    });

    test('reset del PIN durante la visione: il nuovo PIN si chiede a visione finita, una volta sola', () {
      final p = PinAsk();
      expect(p.onReset(watching: true), isFalse);
      expect(p.pending, isTrue);
      expect(p.onViewEnd(), isTrue);
      expect(p.onViewEnd(), isFalse);
    });

    test('nessun avviso sul «fornitore» per «Disconnetti», reset del PIN e permesso', () {
      final sources = [
        'lib/core/panel/panel_service.dart',
        'lib/features/home/shell.dart',
        'android/app/src/main/kotlin/com/kairos/nova/MainActivity.kt',
      ].map((f) => io.File(f).readAsStringSync()).join('\n');
      expect(sources, isNot(contains('ha chiuso la visione')));
      expect(sources, isNot(contains('ha reimpostato il PIN')));
      expect(sources, isNot(contains('Visione interrotta')));
      expect(sources, contains('per gli aggiornamenti dell\'app'));
    });
  });
}
