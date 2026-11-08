import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// Pannello Kairos: dice qual è l'ultima versione (feed della release) e la politica degli aggiornamenti
/// decisa dal fornitore (in background sì/no, obbligatorio dopo N giorni). Se non risponde si legge il feed
/// direttamente da GitHub e si tiene l'ultima politica salvata.
const String kPanelUpdateUrl = 'https://kairos-panel.mariopiccolo8562.workers.dev/api/player/update';
const String kNovaFeedUrl = 'https://github.com/mariopiccolo8562-lang/Lairos-nova/releases/download/latest/kairos-nova.json';

/// Versione nuova trovata.
class UpdateInfo {
  const UpdateInfo({required this.code, required this.version, required this.url});
  final int code;
  final String version;
  final String url;
}

/// Ponte con la parte nativa (MainActivity.kt / Updater.kt): versione installata, download e installazione dell'APK.
class NovaNative {
  NovaNative._();
  static const MethodChannel _ch = MethodChannel('kairos/nova');
  static final StreamController<Map<String, dynamic>> _events = StreamController.broadcast();
  static bool _listening = false;

  static Stream<Map<String, dynamic>> get updateEvents {
    _listen();
    return _events.stream;
  }

  static void _listen() {
    if (_listening) return;
    _listening = true;
    _ch.setMethodCallHandler((call) async {
      if (call.method == 'updateEvent') {
        try {
          final m = jsonDecode(call.arguments as String);
          if (m is Map) _events.add(Map<String, dynamic>.from(m));
        } catch (_) {}
      }
    });
  }

  static Future<Map<String, dynamic>> _call(String method, [Map<String, dynamic>? args]) async {
    _listen();
    try {
      final r = await _ch.invokeMethod<Object?>(method, args);
      return r is Map ? Map<String, dynamic>.from(r) : const {};
    } on Object catch (e) {
      debugPrint('nativo $method: $e');
      return const {};
    }
  }

  static Map<String, dynamic>? _info;

  /// {version, versionCode, sdk, model, tv, lowRam, totalMemMb}; vuoto fuori da Android. Non cambia mentre l'app è
  /// aperta: si chiede alla parte nativa una volta sola (all'avvio), le richieste dopo il primo fotogramma la riusano.
  static Future<Map<String, dynamic>> deviceInfo() async {
    final known = _info;
    if (known != null) return known;
    final r = await _call('deviceInfo');
    if (r.isNotEmpty) _info = r;
    return r;
  }
  static Future<Map<String, dynamic>> updateStatus(int code) => _call('updateStatus', {'code': code});
  static Future<void> updatePrefetch(String url, int code) => _call('updatePrefetch', {'url': url, 'code': code});
  static Future<void> updateInstall(String url, int code) => _call('updateInstall', {'url': url, 'code': code});
}

/// Aggiornamento dell'app.
/// - Controllo all'avvio e ogni ora (feed della release più recente, via pannello Kairos).
/// - Aggiornamento in background (scelta del cliente o imposta dal fornitore, acceso di serie): l'APK si scarica
///   e si verifica in silenzio (solo su Wi-Fi o cavo, mai durante la visione); quando è pronto si propone
///   «Installa ora» e al cliente resta solo la conferma di Android.
/// - Aggiornamento obbligatorio (deciso dal fornitore: subito / dopo 3 o 7 giorni dal primo avviso): scaduto il
///   termine l'app si apre solo dopo aver installato, ma soltanto se l'APK è già pronto sul dispositivo.
/// - La versione trovata (codice, versione, link, APK già pronto) e la politica del fornitore restano salvate sul
///   dispositivo: all'avvio il blocco obbligatorio vale subito, anche senza rete e prima del controllo in rete.
class AppUpdater extends ChangeNotifier {
  AppUpdater(this._prefs, {required this.watching}) {
    _sub = NovaNative.updateEvents.listen(_onEvent);
    _bgLocal = _prefs.getBool('bg_update') ?? true;
    _policy = _decodePolicy(_prefs.getString('upd_policy'));
    _rcPolicy = _savedRemotePolicy(_prefs.getString('kx_rc'));
    _first = _prefs.getString('upd_first') ?? '';
  }

  static const String _kPending = 'upd_pending';

  final SharedPreferences _prefs;

  /// Visione in corso: niente download non richiesti e niente finestre.
  final bool Function() watching;

  StreamSubscription<Map<String, dynamic>>? _sub;
  Timer? _timer;
  DateTime? _lastCheck;
  bool _checking = false;
  int _failed = 0;
  int _offeredCode = 0;
  bool _bgLocal = true;
  Map<String, String> _policy = const {}; // politica pubblica (profilo dell'app nel pannello)
  Map<String, String> _rcPolicy = const {}; // politica del fornitore per questo dispositivo (app collegata): vince
  String _first = '';
  bool _offerDeferred = false; // proposta arrivata durante la visione: si mostra a lettore chiuso
  bool _wantInstall = false; // il cliente ha premuto Installa: si installa appena l'APK è pronto
  bool _permAsked = false; // aperta la schermata «Installa app sconosciute»: al ritorno si riprova da soli

  Map<String, String> get _eff => {..._policy, ..._rcPolicy};

  /// Politica arrivata col battito del fornitore (bgupd, force): vince su quella pubblica.
  void applyRemotePolicy(Map<String, String> p) {
    if (jsonEncode(p) == jsonEncode(_rcPolicy)) return;
    _rcPolicy = Map.unmodifiable(p);
    notifyListeners();
    _maybeOffer(); // es. aggiornamento appena reso obbligatorio
  }

  /// Il fornitore ha chiesto l'aggiornamento («Invia aggiornamento» o comando): controllo subito, anche su rete a consumo.
  Future<String> fromPanel() async {
    final u = await check(force: true);
    if (u == null) return 'già aggiornata ($currentVersion)';
    if (watching()) return 'versione ${u.version}: proposta a fine visione';
    return ready ? 'versione ${u.version} pronta: proposta al cliente' : 'versione ${u.version} in scaricamento';
  }

  /// Versione installata (dalla parte nativa).
  String currentVersion = '';
  int currentCode = 0;

  /// Versione nuova trovata e non ancora installata.
  UpdateInfo? pending;

  /// L'APK di [pending] è già scaricato e verificato.
  bool ready = false;

  /// Avanzamento del download richiesto dal cliente (0-100), -1 se fermo.
  int progress = -1;

  /// Ultimo esito da mostrare.
  String? message;

  /// La versione da proporre: l'interfaccia mostra la finestra e poi rimette null.
  final ValueNotifier<UpdateInfo?> offer = ValueNotifier(null);

  /// Aggiornamenti in background: imposto dal fornitore se c'è, altrimenti scelta del cliente.
  bool get bgUpdate => _eff.containsKey('bgupd') ? _eff['bgupd'] == 'on' : _bgLocal;
  bool get bgImposed => _eff.containsKey('bgupd');

  Future<void> setBgUpdate(bool on) async {
    _bgLocal = on;
    await _prefs.setBool('bg_update', on);
    notifyListeners();
  }

  /// Giorni di grazia dell'aggiornamento obbligatorio, null = il cliente può rimandare.
  int? get forceDays => switch (_eff['force']) { 'now' => 0, '3d' => 3, '7d' => 7, _ => null };

  /// L'app va bloccata: termine scaduto e APK già scaricato e verificato (mai per un problema di rete).
  bool get mustUpdate {
    final u = pending;
    final days = forceDays;
    if (u == null || days == null || !ready) return false;
    final parts = _first.split(':');
    if (parts.length != 2 || int.tryParse(parts[0]) != u.code) return false;
    final first = int.tryParse(parts[1]) ?? 0;
    return DateTime.now().millisecondsSinceEpoch - first >= days * 86400000;
  }

  /// Controllo periodico: all'avvio e poi ogni ora.
  Future<void> start() async {
    final info = await NovaNative.deviceInfo();
    currentVersion = (info['version'] ?? '').toString();
    currentCode = (info['versionCode'] is num) ? (info['versionCode'] as num).toInt() : 0;
    // versione trovata in un'apertura precedente (salvata sul dispositivo): un aggiornamento obbligatorio scaduto
    // blocca subito, anche senza rete e senza aspettare il controllo in rete (che parte tra 25 s); che il file sia
    // ancora lì e valido lo riconferma la parte nativa
    _restorePending();
    notifyListeners();
    if (ready) _maybeOffer();
    unawaited(_confirmReady());
    _timer?.cancel();
    Timer(const Duration(seconds: 25), () => unawaited(check()));
    _timer = Timer.periodic(const Duration(hours: 1), (_) => unawaited(check()));
  }

  /// L'app torna in primo piano: nuovo controllo se l'ultimo è vecchio di oltre 10 minuti; una versione già
  /// trovata si ripropone.
  void onForeground() {
    _offeredCode = 0;
    if (_permAsked) {
      // ritorno dalla schermata del permesso «Installa app sconosciute»: l'installazione riparte da sola
      _permAsked = false;
      unawaited(_installAfterPermission());
      return;
    }
    final last = _lastCheck;
    if (last == null || DateTime.now().difference(last) > const Duration(minutes: 10)) {
      unawaited(check());
    } else {
      _maybeOffer();
    }
  }

  /// Legge il feed e la politica; se c'è una versione nuova la scarica in background (quando è il caso) e la propone.
  /// [manual]: il cliente ha premuto «Controlla»: si propone subito, anche senza download in background.
  Future<UpdateInfo?> check({bool manual = false, bool force = false}) async {
    if (_checking || currentCode <= 0) return pending;
    _checking = true;
    try {
      final feed = await _fetchFeed();
      if (feed == null) {
        if (manual) message = 'Impossibile controllare gli aggiornamenti adesso';
        notifyListeners();
        return pending;
      }
      _lastCheck = DateTime.now();
      final apk = feed['apk'];
      final pol = feed['policy'];
      if (pol is Map) {
        _policy = {for (final e in pol.entries) if (e.value != null) e.key.toString(): e.value.toString()};
        await _prefs.setString('upd_policy', jsonEncode(_policy));
      }
      final m = apk is Map ? apk : const {};
      final version = (m['version'] ?? '').toString().replaceFirst(RegExp(r'^v'), '');
      final code = (m['versionCode'] is num) ? (m['versionCode'] as num).toInt() : int.tryParse('${m['versionCode']}') ?? 0;
      final url = (m['url'] ?? '').toString();
      if (code <= currentCode || !url.startsWith('https://')) {
        pending = null;
        ready = false;
        _savePending();
        if (manual) message = 'Hai già l\'ultima versione ($currentVersion)';
        notifyListeners();
        return null;
      }
      final u = UpdateInfo(code: code, version: version, url: url);
      if (pending?.code != code) {
        ready = false;
        _failed = 0;
        _offeredCode = 0;
      }
      pending = u;
      message = null;
      await _firstSeen(u);
      final st = await NovaNative.updateStatus(code);
      ready = st['ready'] == true;
      _savePending();
      final metered = st['metered'] == true;
      if (!ready && !manual && (bgUpdate || force) && (force || !metered) && !watching() && _failed < 3) {
        await NovaNative.updatePrefetch(url, code); // l'esito arriva con l'evento ready | failed
      } else {
        _maybeOffer(manual: manual);
      }
      notifyListeners();
      return u;
    } finally {
      _checking = false;
    }
  }

  /// Installa la versione trovata: subito se è già scaricata, altrimenti download con avanzamento.
  Future<void> install() async {
    final u = pending;
    if (u == null) return;
    _wantInstall = true;
    message = null;
    progress = ready ? 100 : 0;
    notifyListeners();
    await NovaNative.updateInstall(u.url, u.code);
  }

  /// Feed + politica dal pannello; se non risponde, feed diretto da GitHub e politica salvata.
  Future<Map<String, dynamic>?> _fetchFeed() async {
    final ua = {'User-Agent': 'KairosNova/$currentVersion', 'Accept': 'application/json'};
    try {
      final r = await http.get(Uri.parse(kPanelUpdateUrl), headers: ua).timeout(const Duration(seconds: 12));
      if (r.statusCode == 200) {
        final j = jsonDecode(r.body);
        if (j is Map && j['apk'] is Map) return Map<String, dynamic>.from(j);
      }
    } catch (_) {}
    try {
      final r = await http.get(Uri.parse(kNovaFeedUrl), headers: ua).timeout(const Duration(seconds: 12));
      if (r.statusCode == 200) {
        final j = jsonDecode(r.body);
        if (j is Map) return {'apk': Map<String, dynamic>.from(j), 'policy': _policy};
      }
    } catch (_) {}
    return null;
  }

  Future<void> _firstSeen(UpdateInfo u) async {
    final parts = _first.split(':');
    if (parts.length == 2 && int.tryParse(parts[0]) == u.code) return;
    _first = '${u.code}:${DateTime.now().millisecondsSinceEpoch}';
    await _prefs.setString('upd_first', _first);
  }

  void _maybeOffer({bool manual = false}) {
    final u = pending;
    if (u == null) return;
    if (watching()) {
      _offerDeferred = true; // niente finestre sopra il lettore: si mostra al ritorno nel menu
      return;
    }
    if (!manual && !mustUpdate && _offeredCode == u.code) return;
    _offeredCode = u.code;
    offer.value = u;
  }

  /// Lettore chiuso: la proposta arrivata (o rimandata) mentre si guardava si mostra adesso, nel menu, invece di
  /// perdersi fino al controllo dopo; un aggiornamento obbligatorio scaduto si propone comunque.
  void onWatchingEnded() {
    if (!_offerDeferred && !mustUpdate) return;
    _offerDeferred = false;
    _maybeOffer();
  }

  /// Finestra chiusa («Più tardi»): niente installazioni che partono da sole dopo.
  void cancelPendingInstall() {
    _wantInstall = false;
    _permAsked = false;
  }

  /// Salva sul dispositivo la versione trovata (o la toglie quando non c'è più).
  void _savePending() {
    final u = pending;
    if (u == null) {
      _prefs.remove(_kPending);
    } else {
      _prefs.setString(_kPending, jsonEncode({'code': u.code, 'version': u.version, 'url': u.url, 'ready': ready}));
    }
  }

  /// Versione salvata in un'apertura precedente: vale se è più nuova di quella installata (altrimenti è già installata).
  void _restorePending() {
    final raw = _prefs.getString(_kPending);
    if (raw == null || raw.isEmpty || currentCode <= 0) return;
    try {
      final j = jsonDecode(raw);
      if (j is Map) {
        final code = j['code'] is num ? (j['code'] as num).toInt() : 0;
        final url = (j['url'] ?? '').toString();
        if (code > currentCode && url.startsWith('https://')) {
          pending = UpdateInfo(code: code, version: (j['version'] ?? '').toString(), url: url);
          ready = j['ready'] == true;
          return;
        }
      }
    } catch (_) {}
    _prefs.remove(_kPending);
  }

  /// La parte nativa riconferma che l'APK salvato c'è ancora ed è valido (verifica fuori dal thread dell'interfaccia).
  Future<void> _confirmReady() async {
    final u = pending;
    if (u == null) return;
    final st = await NovaNative.updateStatus(u.code);
    if (st.isEmpty || pending?.code != u.code) return;
    final now = st['ready'] == true;
    if (now != ready) {
      ready = now;
      _savePending();
      notifyListeners();
    }
    if (ready) _maybeOffer();
  }

  /// Ritorno dalla schermata del permesso: se ora è concesso si installa, altrimenti il messaggio lo dice.
  Future<void> _installAfterPermission() async {
    final u = pending;
    if (u == null) return;
    final st = await NovaNative.updateStatus(u.code);
    if (pending?.code != u.code) return;
    if (st['canInstall'] == true) {
      await install();
    } else {
      message = 'Senza il permesso «Installa app sconosciute» per Kairos Nova l\'aggiornamento non si può installare: '
          'premi di nuovo Installa ora e consentilo';
      notifyListeners();
    }
  }

  void _onEvent(Map<String, dynamic> e) {
    final type = (e['type'] ?? '').toString();
    final code = (e['code'] is num) ? (e['code'] as num).toInt() : null;
    switch (type) {
      case 'ready':
        if (code == pending?.code) {
          ready = true;
          _offeredCode = 0;
          _savePending();
          if (_wantInstall) {
            unawaited(install()); // Installa premuto mentre lo scaricamento in background era in corso: si installa ora
          } else {
            _maybeOffer();
          }
        }
      case 'failed':
        _failed++; // si riprova al prossimo controllo (al massimo tre volte per versione)
        if (_wantInstall) {
          // il cliente aspettava questo scaricamento per installare: la finestra non resta ferma
          _wantInstall = false;
          progress = -1;
          message = 'Aggiornamento non riuscito: ${e['msg'] ?? 'errore'}';
        }
        _maybeOffer(); // intanto il cliente può scaricarla a mano
      case 'progress':
        progress = (e['p'] is num) ? (e['p'] as num).toInt() : progress;
      case 'installer':
        _wantInstall = false;
        progress = -1;
        message = 'Conferma l\'installazione nella schermata di Android';
      case 'perm':
        _wantInstall = false;
        _permAsked = true;
        progress = -1;
        message = 'Consenti a Kairos Nova di installare app (permesso «Installa app sconosciute») nella schermata che si è '
            'aperta: tornando qui l\'installazione riparte da sola';
      case 'error':
        _wantInstall = false;
        progress = -1;
        message = 'Aggiornamento non riuscito: ${e['msg'] ?? 'errore'}';
      case 'busy':
        // scaricamento in background già in corso: la finestra non resta ferma, si installa appena è pronto
        progress = -1;
        message = 'Download già in corso: l\'installazione parte appena è pronto';
    }
    notifyListeners();
  }

  /// Voci «bgupd» e «force» del controllo remoto salvate dal pannello (kx_rc), come le passa applyRemotePolicy:
  /// valgono già all'avvio. Prima tornavano solo quando il pannello le cambiava: dopo un riavvio un aggiornamento
  /// reso obbligatorio per questo dispositivo non bloccava più.
  static Map<String, String> _savedRemotePolicy(String? raw) {
    if (raw == null || raw.isEmpty) return const {};
    try {
      final j = jsonDecode(raw);
      if (j is Map) {
        return Map.unmodifiable({
          for (final k in const ['bgupd', 'force'])
            if (j[k] != null) k: j[k].toString(),
        });
      }
    } catch (_) {}
    return const {};
  }

  static Map<String, String> _decodePolicy(String? raw) {
    if (raw == null || raw.isEmpty) return const {};
    try {
      final j = jsonDecode(raw);
      if (j is Map) return {for (final e in j.entries) e.key.toString(): e.value.toString()};
    } catch (_) {}
    return const {};
  }

  @override
  void dispose() {
    _timer?.cancel();
    _sub?.cancel();
    offer.dispose();
    super.dispose();
  }
}
