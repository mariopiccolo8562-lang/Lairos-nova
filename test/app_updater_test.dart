import 'dart:convert';
import 'dart:io';

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

  group('Feed degli aggiornamenti: store-k.download, poi il pannello, poi GitHub', () {
    const dlFeed = 'https://store-k.download/get/nova.json';
    const panel = 'https://panel-kairos.com/get/nova.json';
    const dlApk = 'https://store-k.download/get/nova.apk';
    const dlApk32 = 'https://store-k.download/get/nova-arm32.apk';
    const panelApk = 'https://panel-kairos.com/get/nova.apk';
    const panelApk32 = 'https://panel-kairos.com/get/nova-arm32.apk';
    const ghApk = kNovaApkFallback;
    const ghApk32 = kNovaApk32Fallback;
    final ghFeed = <String, Object?>{'version': '1.0.19', 'versionCode': 19, 'url': ghApk, 'urlArm32': ghApk32};

    test('ordine delle basi: dominio dei download, pannello (saltato se uguale), GitHub', () {
      expect(kDlBase, 'https://store-k.download');
      expect(AppUpdater.feeds, [dlFeed, panel, kNovaFeedUrl]);
      expect(updateFeeds('https://store-k.download/', 'nova', kNovaFeedUrl), [dlFeed, panel, kNovaFeedUrl]);
      expect(updateFeeds('https://panel-kairos.com', 'nova', kNovaFeedUrl), [panel, kNovaFeedUrl]);
      expect(updateFeeds('', 'nova', ''), [panel]);
    });

    test('APK: link del feed, poi le basi successive, alla fine GitHub (64 e 32 bit)', () {
      expect(apkUrls(dlApk, kDlBase, 'nova', ghApk), [dlApk, panelApk, ghApk]);
      expect(apkAlternatives(dlApk), {
        'alts': [panelApk, ghApk],
        'alts32': [panelApk32, ghApk32],
      });
      // feed dal pannello (dominio dei download giù): il dominio dei download non si riprova
      expect(apkAlternatives(panelApk), {
        'alts': [ghApk],
        'alts32': [ghApk32],
      });
      // feed di riserva di GitHub: solo GitHub
      expect(apkAlternatives(ghApk), {
        'alts': <String>[],
        'alts32': [ghApk32],
      });
    });

    test('con la prima base che risponde le altre non si chiedono', () async {
      final asked = <String>[];
      final f = await firstFeed(AppUpdater.feeds, (uri) async {
        asked.add('$uri');
        return <String, Object?>{'version': '1.0.23', 'versionCode': 23, 'url': dlApk, 'urlArm32': dlApk32};
      });
      expect(f?['urlArm32'], dlApk32);
      expect(asked, [dlFeed]);
    });

    test('dominio dei download non attivo o parcheggiato, pannello con errore o JSON non valido → riserva GitHub', () async {
      final failures = <Future<Object?> Function()>[
        () async => throw const SocketException('Failed host lookup: store-k.download'),
        () async => throw const FormatException('<!DOCTYPE html>'), // pagina parcheggiata
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
        expect(asked, [dlFeed, panel, kNovaFeedUrl]);
      }
    });

    test('nessuno risponde (anche GitHub con il repository privato) → nessun feed, come una rete giù', () async {
      expect(await firstFeed(AppUpdater.feeds, (_) async => null), isNull);
    });

    test('dal pannello: link dell\'APK, urlArm32 e riserve passano alla parte nativa; il link a 32 bit resta salvato', () async {
      apkReady = false;
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final asked = <String>[];
      final u = AppUpdater(prefs, watching: () => false, fetchFeed: (uri) async {
        asked.add('$uri');
        if (uri.host == 'store-k.download') throw const SocketException('Failed host lookup: store-k.download');
        return <String, Object?>{'version': '1.0.19', 'versionCode': 19, 'url': panelApk, 'urlArm32': panelApk32};
      });
      u.currentCode = 18;
      u.currentVersion = '1.0.18';
      final found = await u.check();
      expect(found?.code, 19);
      expect(found?.url, panelApk);
      expect(found?.url32, panelApk32);
      expect(asked, [dlFeed, panel]);
      expect(calls.where((c) => c.method == 'updatePrefetch').single.arguments, {
        'url': panelApk,
        'code': 19,
        'url32': panelApk32,
        'alts': [ghApk],
        'alts32': [ghApk32],
      });
      // riaperta l'app (anche senza rete) il link a 32 bit c'è ancora
      final again = AppUpdater(prefs, watching: () => false);
      await again.start();
      expect(again.pending?.code, 19);
      expect(again.pending?.url32, panelApk32);
      await again.install();
      expect(calls.where((c) => c.method == 'updateInstall').single.arguments, {
        'url': panelApk,
        'code': 19,
        'url32': panelApk32,
        'alts': [ghApk],
        'alts32': [ghApk32],
      });
      await settle();
      u.dispose();
      again.dispose();
    });

    test('dominio dei download e pannello giù: versione e link (anche a 32 bit) dalla riserva GitHub', () async {
      apkReady = false;
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final asked = <String>[];
      final u = AppUpdater(prefs, watching: () => false, fetchFeed: (uri) async {
        asked.add('$uri');
        if (uri.host != 'github.com') return null;
        return ghFeed;
      });
      u.currentCode = 18;
      u.currentVersion = '1.0.18';
      final found = await u.check();
      expect(found?.url, ghApk);
      expect(found?.url32, ghApk32);
      expect(asked, [dlFeed, panel, kNovaFeedUrl]);
      expect(calls.where((c) => c.method == 'updatePrefetch').single.arguments, {
        'url': ghApk,
        'code': 19,
        'url32': ghApk32,
        'alts': <String>[],
        'alts32': [ghApk32],
      });
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

  group('Feed dalla rete (server locale)', () {
    late HttpServer server;
    final routes = <String, Object>{};

    setUpAll(() async {
      HttpOverrides.global = null; // client HTTP vero verso il server locale di prova
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) {
        final body = routes[request.uri.path];
        if (body is int) {
          request.response.statusCode = body;
        } else if (body is String) {
          request.response.add(utf8.encode(body));
        }
        request.response.close();
      });
    });

    tearDownAll(() async {
      await server.close(force: true);
    });

    String at(String path) => 'http://127.0.0.1:${server.port}$path';

    test('vale solo una risposta 200 con il JSON del feed: HTML parcheggiato, JSON rotto o errore → base successiva', () async {
      routes['/ok'] = '{"version":"1.0.23","versionCode":23,"url":"https://store-k.download/get/nova.apk","urlArm32":"https://store-k.download/get/nova-arm32.apk"}';
      routes['/parcheggiato'] = '<!DOCTYPE html><html><body>Questo dominio è in vendita</body></html>';
      routes['/rotto'] = '{"version":';
      routes['/campi'] = '{"version":"1.0.23"}';
      routes['/errore'] = 502;
      await expectLater(fetchFeedJson(Uri.parse(at('/parcheggiato'))), throwsA(isA<FormatException>()));
      expect(await fetchFeedJson(Uri.parse(at('/errore'))), isNull);
      final f = await firstFeed([at('/parcheggiato'), at('/rotto'), at('/campi'), at('/errore'), at('/ok')], fetchFeedJson);
      expect(f?['versionCode'], 23);
      expect(f?['urlArm32'], 'https://store-k.download/get/nova-arm32.apk');
    });

    test('indirizzo che non risponde (connessione rifiutata): si passa subito al successivo', () async {
      routes['/ok'] = '{"version":"1.0.23","versionCode":23,"url":"https://panel-kairos.com/get/nova.apk"}';
      final closed = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = closed.port;
      await closed.close();
      final watch = Stopwatch()..start();
      final f = await firstFeed(['http://127.0.0.1:$port/get/nova.json', at('/ok')], fetchFeedJson);
      expect(f?['versionCode'], 23);
      expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
    });
  });
}
