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
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
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

  group('Feed degli aggiornamenti: pannello prima, GitHub solo di riserva', () {
    const panel = 'https://panel-kairos.com/get/nova.json';
    const panelApk = 'https://panel-kairos.com/get/nova.apk';
    const panelApk32 = 'https://panel-kairos.com/get/nova-arm32.apk';
    const ghApk = 'https://github.com/mariopiccolo8562-lang/Lairos-nova/releases/download/latest/KairosNova-arm64.apk';
    const ghApk32 = 'https://github.com/mariopiccolo8562-lang/Lairos-nova/releases/download/latest/KairosNova-arm32.apk';
    final ghFeed = <String, Object?>{'version': '1.0.19', 'versionCode': 19, 'url': ghApk, 'urlArm32': ghApk32};

    test('ordine: indirizzo dei download, pannello (saltato se uguale), GitHub', () {
      // oggi l'indirizzo dei download è il pannello: il secondo tentativo, uguale al primo, si salta
      expect(AppUpdater.feeds, [panel, kNovaFeedUrl]);
      expect(updateFeeds('https://panel-kairos.com/', 'nova', kNovaFeedUrl), [panel, kNovaFeedUrl]);
      expect(updateFeeds('https://dl.example.com', 'nova', kNovaFeedUrl), ['https://dl.example.com/get/nova.json', panel, kNovaFeedUrl]);
      expect(updateFeeds('', 'nova', ''), [panel]);
    });

    test('con il pannello che risponde GitHub non si chiede', () async {
      final asked = <String>[];
      final f = await firstFeed(AppUpdater.feeds, (uri) async {
        asked.add('$uri');
        return <String, Object?>{'version': '1.0.23', 'versionCode': 23, 'url': panelApk, 'urlArm32': panelApk32};
      });
      expect(f?['versionCode'], 23);
      expect(f?['urlArm32'], panelApk32);
      expect(asked, [panel]); // nessun controllo in più del solito
    });

    test('pannello muto, con errore o con un JSON non valido → riserva GitHub', () async {
      final failures = <Future<Object?> Function()>[
        () async => throw Exception('nessuna risposta'),
        () async => null, // risposta diversa da 200 (es. 502)
        () async => <String, Object?>{'error': 'non disponibile'},
        () async => 'pagina di errore',
        () async => <String, Object?>{'version': '1.0.23', 'versionCode': 23, 'url': 'http://panel-kairos.com/get/nova.apk'},
      ];
      for (final fail in failures) {
        final asked = <String>[];
        final f = await firstFeed(AppUpdater.feeds, (uri) async {
          asked.add('$uri');
          if ('$uri' == kNovaFeedUrl) return ghFeed;
          return fail();
        });
        expect(f?['url'], ghApk);
        expect(asked, [panel, kNovaFeedUrl]);
      }
    });

    test('nessuno risponde (anche GitHub con il repository privato) → nessun feed, come una rete giù', () async {
      expect(await firstFeed(AppUpdater.feeds, (_) async => null), isNull);
    });

    test('dal pannello: il link dell\'APK e quello a 32 bit (urlArm32) passano alla parte nativa e restano salvati', () async {
      apkReady = false;
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final asked = <String>[];
      final u = AppUpdater(prefs, watching: () => false, fetchFeed: (uri) async {
        asked.add('$uri');
        return <String, Object?>{'version': '1.0.19', 'versionCode': 19, 'url': panelApk, 'urlArm32': panelApk32};
      });
      u.currentCode = 18;
      u.currentVersion = '1.0.18';
      final found = await u.check();
      expect(found?.code, 19);
      expect(found?.url, panelApk);
      expect(found?.url32, panelApk32);
      expect(asked, [panel]);
      expect(calls.where((c) => c.method == 'updatePrefetch').single.arguments, {'url': panelApk, 'code': 19, 'url32': panelApk32});
      // riaperta l'app (anche senza rete) il link a 32 bit c'è ancora
      final again = AppUpdater(prefs, watching: () => false);
      await again.start();
      expect(again.pending?.code, 19);
      expect(again.pending?.url32, panelApk32);
      await settle();
      u.dispose();
      again.dispose();
    });

    test('pannello giù: versione e link (anche a 32 bit) dalla riserva GitHub', () async {
      apkReady = false;
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final asked = <String>[];
      final u = AppUpdater(prefs, watching: () => false, fetchFeed: (uri) async {
        asked.add('$uri');
        if (uri.host == 'panel-kairos.com') return null;
        return ghFeed;
      });
      u.currentCode = 18;
      u.currentVersion = '1.0.18';
      final found = await u.check();
      expect(found?.url, ghApk);
      expect(found?.url32, ghApk32);
      expect(asked, [panel, kNovaFeedUrl]);
      expect(calls.where((c) => c.method == 'updatePrefetch').single.arguments, {'url': ghApk, 'code': 19, 'url32': ghApk32});
      u.dispose();
    });

    test('feed non valido ovunque: la versione trovata prima resta, niente «già aggiornata»', () async {
      apkReady = true;
      SharedPreferences.setMockInitialValues(saved(daysAgo: 0, force: ''));
      final prefs = await SharedPreferences.getInstance();
      final u = AppUpdater(prefs, watching: () => false, fetchFeed: (_) async => <String, Object?>{});
      await u.start();
      expect(u.pending?.code, 19);
      expect(await u.check(manual: true), isNotNull);
      expect(u.pending?.code, 19);
      expect(u.message, 'Impossibile controllare gli aggiornamenti adesso');
      await settle();
      u.dispose();
    });
  });
}
