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

  group('Feed degli aggiornamenti: store-k.download, poi le riserve (niente pannello né GitHub)', () {
    const dlFeed = 'https://store-k.download/get/nova.json';
    const dlApk = 'https://store-k.download/get/nova.apk';
    const dlApk32 = 'https://store-k.download/get/nova-arm32.apk';
    const res = 'https://riserva-k.download';
    const res2 = 'https://riserva2-k.download';
    const resFeed = '$res/get/nova.json';
    const resApk = '$res/get/nova.apk';
    const resApk32 = '$res/get/nova-arm32.apk';
    const res2Apk = '$res2/get/nova.apk';
    const res2Apk32 = '$res2/get/nova-arm32.apk';

    Future<AppUpdater> fresh(Future<Object?> Function(Uri uri) fetch, {Map<String, Object> stored = const {}}) async {
      SharedPreferences.setMockInitialValues(stored);
      final prefs = await SharedPreferences.getInstance();
      final u = AppUpdater(prefs, watching: () => false, fetchFeed: fetch);
      u.currentCode = 18;
      u.currentVersion = '1.0.18';
      return u;
    }

    test('ordine delle basi: dominio dei download, poi le riserve; http, percorsi e doppioni si scartano', () async {
      expect(kDlBase, 'https://store-k.download');
      final u = await fresh((_) async => null);
      expect(u.feeds, [dlFeed]);
      expect(updateFeeds('https://store-k.download/', 'nova'), [dlFeed]);
      expect(updateFeeds(kDlBase, 'nova', ['', '$res/', kDlBase]), [dlFeed, resFeed]);
      expect(updateFeeds('http://store-k.download', 'nova', ['$res/x', 'riserva-k.download', res2]), ['$res2/get/nova.json']);
      expect(updateFeeds('', 'nova'), isEmpty);
      expect(downloadBases(kDlBase, ['https://a-k.download', 'https://b-k.download', 'https://c-k.download', 'https://d-k.download']),
          [kDlBase, 'https://a-k.download', 'https://b-k.download', 'https://c-k.download']);
      final all = updateFeeds(kDlBase, 'nova', [kDlBase2, res]).join(' ');
      expect(all, isNot(contains('panel-kairos.com')));
      expect(all, isNot(contains('github.com')));
      u.dispose();
    });

    test('APK: link del feed, poi le basi successive (64 e 32 bit); un link fuori dalle basi passa a tutte', () {
      const extra = [res, res2];
      expect(apkUrls(dlApk, kDlBase, 'nova'), [dlApk]);
      // l'APK a 32 bit del feed («urlArm32», sulla stessa base) lo prova prima la parte nativa: qui solo le basi dopo
      expect(apkAlternatives(dlApk), {
        'alts': <String>[],
        'alts32': <String>[],
      });
      expect(apkAlternatives(dlApk, extra: extra), {
        'alts': [resApk, res2Apk],
        'alts32': [resApk32, res2Apk32],
      });
      // feed dalla riserva (dominio dei download giù): il dominio dei download non si riprova
      expect(apkAlternatives(resApk, extra: extra), {
        'alts': [res2Apk],
        'alts32': [res2Apk32],
      });
      // link fuori dalle basi: il suo link, poi tutte le basi
      const other = 'https://cdn.example.org/KairosNova-arm64.apk';
      expect(apkAlternatives(other, extra: extra), {
        'alts': [dlApk, resApk, res2Apk],
        'alts32': [dlApk32, resApk32, res2Apk32],
      });
    });

    test('«mirrors» del feed: solo https validi, senza doppioni, al massimo 3; senza lista → null', () {
      expect(
        feedMirrors(<String, Object?>{
          'mirrors': [kDlBase, '$res/', 'http://x-k.download', res, 5, 'https://a-k.download', 'https://b-k.download'],
        }),
        [kDlBase, res, 'https://a-k.download'],
      );
      expect(feedMirrors(<String, Object?>{'mirrors': <Object?>[]}), isEmpty);
      expect(feedMirrors(<String, Object?>{'version': '1.0.23'}), isNull);
      expect(feedMirrors(<String, Object?>{'mirrors': res}), isNull);
      expect(feedMirrors('pagina'), isNull);
    });

    test('con la prima base che risponde le altre non si chiedono', () async {
      final asked = <String>[];
      final f = await firstFeed(updateFeeds(kDlBase, 'nova', [res]), (uri) async {
        asked.add('$uri');
        return <String, Object?>{'version': '1.0.23', 'versionCode': 23, 'url': dlApk, 'urlArm32': dlApk32};
      });
      expect(f?['urlArm32'], dlApk32);
      expect(asked, [dlFeed]);
    });

    test('dominio dei download non attivo, parcheggiato, con errore o JSON non valido → la riserva', () async {
      final failures = <Future<Object?> Function()>[
        () async => throw const SocketException('Failed host lookup: store-k.download'),
        () async => throw const FormatException('<!DOCTYPE html>'), // pagina parcheggiata
        () async => null, // risposta diversa da 200 (es. 502)
        () async => <String, Object?>{'error': 'non disponibile'},
        () async => 'pagina di errore',
        () async => <String, Object?>{'version': '1.0.23', 'versionCode': 23, 'url': 'http://store-k.download/get/nova.apk'},
      ];
      for (final fail in failures) {
        final asked = <String>[];
        final f = await firstFeed(updateFeeds(kDlBase, 'nova', [res]), (uri) async {
          asked.add('$uri');
          if ('$uri' == resFeed) return <String, Object?>{'version': '1.0.23', 'versionCode': 23, 'url': resApk, 'urlArm32': resApk32};
          return fail();
        });
        expect(f?['url'], resApk);
        expect(asked, [dlFeed, resFeed]);
      }
    });

    test('nessuno risponde → nessun feed, come una rete giù', () async {
      expect(await firstFeed(updateFeeds(kDlBase, 'nova', [res]), (_) async => null), isNull);
    });

    test('feed del dominio dei download: link dell\'APK, urlArm32 e basi successive alla parte nativa; il link a 32 bit resta salvato', () async {
      apkReady = false;
      final asked = <String>[];
      final u = await fresh((uri) async {
        asked.add('$uri');
        return <String, Object?>{'version': '1.0.19', 'versionCode': 19, 'url': dlApk, 'urlArm32': dlApk32};
      });
      final found = await u.check();
      expect(found?.code, 19);
      expect(found?.url, dlApk);
      expect(found?.url32, dlApk32);
      expect(asked, [dlFeed]);
      expect(calls.where((c) => c.method == 'updatePrefetch').single.arguments, {
        'url': dlApk,
        'code': 19,
        'url32': dlApk32,
        'alts': <String>[],
        'alts32': <String>[],
      });
      // riaperta l'app (anche senza rete) il link a 32 bit c'è ancora
      final prefs = await SharedPreferences.getInstance();
      final again = AppUpdater(prefs, watching: () => false);
      await again.start();
      expect(again.pending?.code, 19);
      expect(again.pending?.url32, dlApk32);
      await again.install();
      expect(calls.where((c) => c.method == 'updateInstall').single.arguments, {
        'url': dlApk,
        'code': 19,
        'url32': dlApk32,
        'alts': <String>[],
        'alts32': <String>[],
      });
      await settle();
      u.dispose();
      again.dispose();
    });

    test('i domini di riserva annunciati dal feed si salvano e valgono dal controllo dopo (anche riaprendo l\'app)', () async {
      apkReady = false;
      final asked = <String>[];
      var dlDown = false;
      final u = await fresh((uri) async {
        asked.add('$uri');
        if (dlDown && uri.host == 'store-k.download') throw const SocketException('Failed host lookup: store-k.download');
        return <String, Object?>{
          'version': '1.0.19',
          'versionCode': 19,
          'url': 'https://${uri.host}/get/nova.apk',
          'urlArm32': 'https://${uri.host}/get/nova-arm32.apk',
          if (uri.host == 'store-k.download') 'mirrors': [kDlBase, res],
        };
      });
      await u.check();
      expect(asked, [dlFeed]);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('dl_mirrors'), '$kDlBase\n$res');
      expect(u.feeds, [dlFeed, resFeed]);
      // il dominio dei download si spegne: la riserva imparata dal feed risponde
      dlDown = true;
      asked.clear();
      calls.clear();
      final found = await u.check(force: true);
      expect(asked, [dlFeed, resFeed]);
      expect(found?.url, resApk);
      expect(found?.url32, resApk32);
      expect(prefs.getString('dl_mirrors'), '$kDlBase\n$res'); // il feed della riserva non ha la lista: restano
      // riaperta l'app le riserve ci sono ancora
      final again = AppUpdater(prefs, watching: () => false);
      expect(again.feeds, [dlFeed, resFeed]);
      u.dispose();
      again.dispose();
    });

    test('lista «mirrors» vuota nel feed: le riserve salvate si tolgono', () async {
      final u = await fresh(
        (_) async => <String, Object?>{'version': '1.0.18', 'versionCode': 18, 'url': dlApk, 'mirrors': <String>[]},
        stored: {'dl_mirrors': res},
      );
      expect(u.feeds, [dlFeed, resFeed]);
      await u.check();
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('dl_mirrors'), isNull);
      expect(u.feeds, [dlFeed]);
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
      routes['/ok'] = '{"version":"1.0.23","versionCode":23,"url":"https://store-k.download/get/nova.apk"}';
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
