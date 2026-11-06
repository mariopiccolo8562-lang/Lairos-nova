import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/kairos_theme.dart';
import '../../core/update/app_updater.dart';

bool _open = false;

/// Propone la versione nuova: «Installa ora» se l'APK è già scaricato in background, altrimenti «Aggiorna ora»
/// con l'avanzamento. Se l'aggiornamento è obbligatorio e scaduto, la finestra non si chiude finché non si installa.
Future<void> showUpdateDialog(BuildContext context, AppUpdater updater) async {
  final u = updater.pending;
  if (u == null || _open) return;
  _open = true;
  try {
    final must = updater.mustUpdate;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => ListenableBuilder(
        listenable: updater,
        builder: (context, _) {
          final ready = updater.ready;
          final p = updater.progress;
          final downloading = p >= 0 && p < 100;
          return PopScope(
            canPop: !must && !downloading,
            child: AlertDialog(
              backgroundColor: KairosColors.surfaceHi,
              title: Text(must
                  ? 'Aggiornamento ${u.version} necessario'
                  : ready
                      ? 'Aggiornamento ${u.version} pronto'
                      : 'Nuova versione ${u.version}'),
              content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(must
                    ? 'Per continuare a usare Kairos Nova va installata la versione nuova: è già scaricata e verificata. Premi Installa e conferma nella schermata di Android, ci vuole meno di un minuto.'
                    : ready
                        ? 'È già scaricata e verificata: premi Installa e conferma nella schermata di Android. Ci vuole meno di un minuto.'
                        : 'Contiene miglioramenti e correzioni. Il download richiede pochi secondi, poi conferma l\'installazione nella schermata di Android.'),
                if (downloading) ...[
                  const SizedBox(height: 16),
                  LinearProgressIndicator(value: p / 100, color: KairosColors.cyan),
                  const SizedBox(height: 6),
                  Text('Download $p%', style: const TextStyle(color: KairosColors.textDim, fontSize: 12)),
                ],
                if (updater.message != null) ...[
                  const SizedBox(height: 12),
                  Text(updater.message!, style: const TextStyle(color: KairosColors.amber, fontSize: 13)),
                ],
              ]),
              actions: [
                if (must)
                  TextButton(onPressed: () => SystemNavigator.pop(), child: const Text('Chiudi l\'app'))
                else
                  TextButton(onPressed: downloading ? null : () => Navigator.pop(context), child: const Text('Più tardi')),
                FilledButton(
                  autofocus: true,
                  onPressed: downloading ? null : () => unawaited(updater.install()),
                  child: Text(ready ? 'Installa ora' : (p == -1 && updater.message != null && !ready ? 'Riprova' : 'Aggiorna ora')),
                ),
              ],
            ),
          );
        },
      ),
    );
  } finally {
    _open = false;
  }
}
