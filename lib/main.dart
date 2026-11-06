import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app.dart';
import 'core/db/kairos_db.dart';
import 'core/providers.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();

  // Cache immagini: migliaia di loghi senza saturare la RAM.
  PaintingBinding.instance.imageCache.maximumSize = 600;
  PaintingBinding.instance.imageCache.maximumSizeBytes = 80 * 1024 * 1024;

  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    systemNavigationBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
  ));
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);

  await initializeDateFormatting('it');
  Intl.defaultLocale = 'it';

  final db = await KairosDb.open();
  final prefs = await SharedPreferences.getInstance();

  runApp(ProviderScope(
    overrides: [
      dbProvider.overrideWithValue(db),
      prefsProvider.overrideWithValue(prefs),
    ],
    child: const KairosApp(),
  ));
}
