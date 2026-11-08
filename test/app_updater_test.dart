import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kairos_nova/core/update/app_updater.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Flusso dell'aggiornamento senza rete: tutto parte dallo stato salvato sul dispositivo e dalla parte nativa (finta).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('kairos/nova');
  var apkReady = true;

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'deviceInfo':
          return <String, Object>{'version': '1.0.18', 'versionCode': 18, 'sdk': 28, 'model': 'AFTSS'};
        case 'updateStatus':
          return <String, Object>{'ready': apkReady, 'metered': false, 'busy': false, 'canInstall': true};
      }
      return null;
    });
  });

  Map<String, Object> saved({bool ready = true, int daysAgo = 8, String force = '7d'}) => {
        'upd_pending': jsonEncode({'code': 19, 'version': '1.0.19', 'url': 'https://example.com/n.apk', 'ready': ready}),
        'upd_first': '19:${DateTime.now().subtract(Duration(days: daysAgo)).millisecondsSinceEpoch}',
        'kx_rc': jsonEncode({'force': force}),
      };

  Future<AppUpdater> started(bool Function() watching, List<UpdateInfo> offers) async {
    final prefs = await SharedPreferences.getInstance();
    final u = AppUpdater(prefs, watching: watching);
    u.offer.addListener(() {
      final v = u.offer.value;
      if (v != null) offers.add(v);
    });
    await u.start();
    return u;
  }

  // la riconferma della parte nativa finisce prima di chiudere l'aggiornatore
  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 60));

  test('obbligatorio scaduto (politica del fornitore salvata): la finestra parte subito all\'avvio, senza rete', () async {
    apkReady = true;
    SharedPreferences.setMockInitialValues(saved());
    final offers = <UpdateInfo>[];
    final u = await started(() => false, offers);
    expect(u.pending?.code, 19);
    expect(u.mustUpdate, isTrue);
    expect(offers.map((e) => e.code), [19]);
    await settle();
    expect(u.mustUpdate, isTrue);
    u.dispose();
  });

  test('proposta arrivata durante la visione: niente finestra sopra il lettore, si mostra a lettore chiuso', () async {
    apkReady = true;
    SharedPreferences.setMockInitialValues(saved(daysAgo: 0, force: ''));
    var watching = true;
    final offers = <UpdateInfo>[];
    final u = await started(() => watching, offers);
    expect(u.mustUpdate, isFalse);
    expect(offers, isEmpty);
    watching = false;
    u.onWatchingEnded();
    expect(offers.map((e) => e.code), [19]);
    await settle();
    expect(offers.length, 1);
    u.dispose();
  });

  test('versione salvata già installata: si dimentica', () async {
    SharedPreferences.setMockInitialValues({
      'upd_pending': jsonEncode({'code': 18, 'version': '1.0.18', 'url': 'https://example.com/n.apk', 'ready': true}),
    });
    final offers = <UpdateInfo>[];
    final u = await started(() => false, offers);
    expect(u.pending, isNull);
    expect(offers, isEmpty);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('upd_pending'), isNull);
    await settle();
    u.dispose();
  });

  test('APK salvato non più valido: la parte nativa toglie il blocco (mai bloccati senza poter installare)', () async {
    apkReady = false;
    SharedPreferences.setMockInitialValues(saved());
    final offers = <UpdateInfo>[];
    final u = await started(() => false, offers);
    expect(u.mustUpdate, isTrue);
    await settle();
    expect(u.ready, isFalse);
    expect(u.mustUpdate, isFalse);
    u.dispose();
  });
}
