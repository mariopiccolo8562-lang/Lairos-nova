import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'models/models.dart';
import 'providers.dart';
import 'theme/kairos_theme.dart';

/// Controllo genitori: attivo di serie con il PIN 0000. Al primo avvio l'app chiede di scegliere un PIN proprio
/// («Più tardi» rimanda al giorno dopo). I gruppi e i canali per adulti chiedono il PIN una volta per apertura.
/// Il fornitore può riportare il PIN a 0000 dal pannello Kairos Control (comando «Reimposta PIN controllo genitori»).
/// Stesse regole di riconoscimento delle altre app Kairos.
final RegExp adultGroupRx = RegExp(
    r'(\bxxx\b|adult|adulti|\bporn|erotic|erotik|hentai|\b18\s*\+|\+\s*18\b|\bvm\s*18\b|for adults|\bsexy?\b|\bhot\s*club\b|playboy|brazzers|private\s*tv)',
    caseSensitive: false);
final RegExp adultNameRx = RegExp(r'(\bxxx\b|\bporn|hentai|brazzers|playboy\s*tv|\b18\s*\+)', caseSensitive: false);

bool isAdultGroup(String? g) => g != null && g.isNotEmpty && adultGroupRx.hasMatch(g);
bool isAdultChannel(Channel c) => isAdultGroup(c.groupName) || adultNameRx.hasMatch(c.name);

/// Il gruppo / canale è protetto adesso (controllo attivo, non ancora sbloccato in questa apertura).
bool parentalLockedGroup(WidgetRef ref, String? group) =>
    ref.read(settingsProvider).parentalOn && !ref.read(parentalUnlockedProvider) && isAdultGroup(group);
bool parentalLockedChannel(WidgetRef ref, Channel c) =>
    ref.read(settingsProvider).parentalOn && !ref.read(parentalUnlockedProvider) && isAdultChannel(c);

/// Finestra del PIN (4 cifre); null se annullata.
Future<String?> askPinDialog(BuildContext context, {required String title, String? hint}) {
  final c = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: KairosColors.surfaceHi,
      title: Text(title),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        if (hint != null) Padding(padding: const EdgeInsets.only(bottom: 10), child: Text(hint, style: const TextStyle(fontSize: 13))),
        TextField(
          controller: c,
          autofocus: true,
          keyboardType: TextInputType.number,
          maxLength: 4,
          obscureText: true,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 26, letterSpacing: 10, fontWeight: FontWeight.w700),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Annulla')),
        FilledButton(onPressed: () => Navigator.pop(ctx, c.text), child: const Text('OK')),
      ],
    ),
  );
}

Future<void> _info(BuildContext context, String title, String msg) => showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: KairosColors.surfaceHi,
        title: Text(title),
        content: Text(msg),
        actions: [FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
      ),
    );

/// Gruppo o canale protetto: chiede il PIN; se è giusto sblocca per questa apertura. True = si può procedere.
Future<bool> parentalGate(BuildContext context, WidgetRef ref, {String? group, Channel? channel}) async {
  final locked = channel != null ? parentalLockedChannel(ref, channel) : parentalLockedGroup(ref, group);
  if (!locked) return true;
  final p = await askPinDialog(context, title: 'Contenuto protetto', hint: 'Controllo genitori: inserisci il PIN di 4 cifre');
  if (p == null || !context.mounted) return false;
  if (ref.read(settingsProvider).checkPin(p)) {
    ref.read(parentalUnlockedProvider.notifier).state = true;
    return true;
  }
  await _info(context, 'PIN errato', 'Il PIN non è giusto. Se lo hai dimenticato, chiedi al tuo fornitore di reimpostarlo.');
  return false;
}

/// Scelta di un PIN nuovo (chiesto due volte). True se impostato.
Future<bool> chooseParentalPin(BuildContext context, WidgetRef ref) async {
  final a = await askPinDialog(context, title: 'Scegli un PIN di 4 cifre', hint: 'Lo userai per i gruppi e i canali per adulti');
  if (a == null || !context.mounted) return false;
  if (a.trim().length != 4 || int.tryParse(a.trim()) == null) {
    await _info(context, 'PIN non valido', 'Il PIN deve avere 4 cifre.');
    return false;
  }
  if (a.trim() == '0000') {
    await _info(context, 'PIN non valido', '0000 è il PIN iniziale: scegline un altro.');
    return false;
  }
  if (!context.mounted) return false;
  final b = await askPinDialog(context, title: 'Ripeti il PIN');
  if (b == null || !context.mounted) return false;
  if (a.trim() != b.trim()) {
    await _info(context, 'PIN non valido', 'I due PIN non coincidono.');
    return false;
  }
  ref.read(settingsProvider.notifier).update((x) => x.copyWith(parentalPin: a.trim(), pinLater: 0));
  return true;
}

bool _asking = false;

/// Primo avvio (o PIN reimpostato dal fornitore): si propone di scegliere il proprio PIN; «Più tardi» rimanda al giorno dopo.
Future<void> maybeAskParentalPin(BuildContext context, WidgetRef ref, {bool force = false}) async {
  final s = ref.read(settingsProvider);
  if (_asking || !s.parentalOn || !s.pinIsDefault) return;
  if (!force && DateTime.now().millisecondsSinceEpoch - s.pinLater < 86400000) return;
  _asking = true;
  try {
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: KairosColors.surfaceHi,
        title: const Text('Controllo genitori'),
        content: const Text('Il controllo genitori è attivo: i gruppi e i canali per adulti chiedono un PIN. Ora il PIN è 0000: scegline uno tuo di 4 cifre.\n\nPuoi farlo anche dopo, da Impostazioni.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Più tardi')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Scegli il PIN')),
        ],
      ),
    );
    if (!context.mounted) return;
    final done = go == true && await chooseParentalPin(context, ref);
    if (!done) ref.read(settingsProvider.notifier).update((x) => x.copyWith(pinLater: DateTime.now().millisecondsSinceEpoch));
  } finally {
    _asking = false;
  }
}
