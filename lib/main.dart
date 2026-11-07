import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app.dart';
import 'core/db/kairos_db.dart';
import 'core/device_tier.dart';
import 'core/providers.dart';
import 'core/update/app_updater.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();

  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    systemNavigationBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
  ));

  // Avvio a freddo: le attese indipendenti (database, preferenze, dati del dispositivo, modalità schermo, formati
  // delle date) partono tutte insieme invece che una dopo l'altra (quasi tutte passano dalla parte nativa).
  final boot = await Future.wait<Object?>([
    KairosDb.open(),
    SharedPreferences.getInstance(),
    NovaNative.deviceInfo(),
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge),
    initializeDateFormatting('it'),
  ]);
  Intl.defaultLocale = 'it';
  final db = boot[0] as KairosDb;
  final prefs = boot[1] as SharedPreferences;
  // classe del dispositivo (D = debole) prima del primo fotogramma: grafica e cache si regolano da subito
  DeviceTier.init(boot[2]);

  // Cache immagini in memoria (già decodificate): migliaia di loghi senza saturare la RAM. Tetto per classe: sui
  // dispositivi deboli (1 GB) ~1/8 della memoria dell'app, 24 MB; sugli altri come sempre. Con poca memoria il
  // sistema avvisa (onTrimMemory/onLowMemory) e Flutter svuota da sé questa cache.
  PaintingBinding.instance.imageCache.maximumSize = DeviceTier.weak ? 300 : 600;
  PaintingBinding.instance.imageCache.maximumSizeBytes = (DeviceTier.weak ? 24 : 80) * 1024 * 1024;

  runApp(ProviderScope(
    overrides: [
      dbProvider.overrideWithValue(db),
      prefsProvider.overrideWithValue(prefs),
    ],
    child: const KairosApp(),
  ));
}
