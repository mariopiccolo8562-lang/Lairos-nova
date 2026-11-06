import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

/// Indirizzo del pannello Kairos (lo stesso di Kairos Pro, TV, Lite, XC e Plus).
const String kDefaultPanelUrl = 'https://panel-kairos.com';

/// Indirizzo di riserva se il dominio non risponde (rete che lo blocca): l'app ricorda quello che funziona.
const List<String> kFallbackPanelUrls = ['https://kairos-panel.mariopiccolo8562.workers.dev'];

class PanelException implements Exception {
  const PanelException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Codice di attivazione (KX12-AB34, come le altre app Kairos) e segreto del dispositivo.
class PanelIdentity {
  const PanelIdentity(this.code, this.secret);
  final String code;
  final String secret;

  static const String _alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

  factory PanelIdentity.generate() {
    final r = Random.secure();
    String ch() => _alphabet[r.nextInt(_alphabet.length)];
    final code = 'KX${ch()}${ch()}-${ch()}${ch()}${ch()}${ch()}';
    final bytes = List<int>.generate(32, (_) => r.nextInt(256));
    return PanelIdentity(code, base64Url.encode(bytes).replaceAll('=', ''));
  }

  static final RegExp codePattern = RegExp(r'^KX[A-Z0-9]{2}-[A-Z0-9]{4}$');
  static final RegExp secretPattern = RegExp(r'^[A-Za-z0-9_-]{32,100}$');
  bool get isValid => codePattern.hasMatch(code) && secretPattern.hasMatch(secret);
}

/// Lista assegnata dal fornitore (Xtream oppure M3U).
class PanelPlaylist {
  const PanelPlaylist({required this.id, required this.name, required this.type, this.url = '', this.host = '', this.username = '', this.password = ''});
  final String id;
  final String name;
  final String type; // xtream | m3u
  final String url;
  final String host;
  final String username;
  final String password;

  bool get isXtream => type == 'xtream' && host.isNotEmpty && username.isNotEmpty;

  /// Server Xtream con schema e senza barra finale.
  String get server {
    var h = host.trim();
    if (!h.startsWith('http://') && !h.startsWith('https://')) h = 'http://$h';
    return h.replaceAll(RegExp(r'/+$'), '');
  }

  /// Link M3U completo.
  String get m3uUrl {
    final t = url.trim();
    if (t.isEmpty) return t;
    return t.startsWith('http://') || t.startsWith('https://') ? t : 'http://$t';
  }

  /// Impronta della lista: se cambia, la lista va rifatta.
  String get signature => '$id|$type|${isXtream ? '$server|$username|$password' : m3uUrl}';

  static PanelPlaylist fromJson(Object? json) {
    final m = json is Map ? json : const {};
    String s(String k) => (m[k] ?? '').toString();
    return PanelPlaylist(id: s('id'), name: s('name').isEmpty ? 'Lista' : s('name'), type: s('type').isEmpty ? 'm3u' : s('type'), url: s('url'), host: s('host'), username: s('username'), password: s('password'));
  }
}

/// Stato del dispositivo restituito da /api/player/register.
class PanelState {
  const PanelState({required this.status, this.name = '', this.expires = '', this.playlists = const [], this.maintMsg = '', this.raw = const {}});

  /// active | pending | locked | expired | disabled | maintenance
  final String status;
  final String name;
  final String expires;
  final List<PanelPlaylist> playlists;
  final String maintMsg;
  final Map<String, dynamic> raw;

  bool get active => status == 'active';
  bool get pending => status == 'pending';

  static PanelState parse(Map<String, dynamic> j) => PanelState(
        status: (j['status'] ?? 'pending').toString(),
        name: (j['name'] ?? '').toString(),
        expires: (j['expires'] ?? '').toString(),
        playlists: [for (final p in (j['playlists'] is List ? j['playlists'] as List : const [])) PanelPlaylist.fromJson(p)],
        maintMsg: (j['maintMsg'] ?? '').toString(),
        raw: j,
      );

  static const PanelState locked = PanelState(status: 'locked');

  String get statusLabel => switch (status) {
        'active' => 'Attivo',
        'pending' => 'In attesa di attivazione',
        'expired' => 'Scaduto',
        'disabled' => 'Disattivato',
        'locked' => 'Bloccato',
        'maintenance' => 'In manutenzione',
        _ => status,
      };

  /// Scadenza leggibile: 05/11/2026.
  String get expiresLabel {
    final d = DateTime.tryParse(expires);
    if (d == null) return expires;
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(d.day)}/${two(d.month)}/${d.year}';
  }
}

class PanelResponse {
  const PanelResponse(this.status, this.body);
  final int status;
  final Map<String, dynamic>? body;
}

/// API del pannello per i dispositivi (/api/player/…), le stesse delle altre app Kairos.
class PanelClient {
  PanelClient({required this.identity, required this.server, required this.model, required this.version, this.onServerChanged});

  final PanelIdentity identity;
  String server;
  final String model;
  final String version;
  final void Function(String server)? onServerChanged;

  /// Versione mostrata nel pannello: «nova 1.0.12».
  String get ver {
    final v = 'nova ${version.isEmpty ? '0' : version}';
    return v.length > 20 ? v.substring(0, 20) : v;
  }

  static String _trim(String u) => u.endsWith('/') ? u.substring(0, u.length - 1) : u;

  Map<String, Object?> _auth() => {'code': identity.code, 'secret': identity.secret};

  Future<PanelResponse> _post(String path, Map<String, Object?> body, {Duration timeout = const Duration(seconds: 20)}) async {
    final servers = <String>[server, for (final f in kFallbackPanelUrls) if (_trim(f) != _trim(server)) f];
    PanelException? last;
    for (final s in servers) {
      try {
        final r = await http
            .post(Uri.parse('${_trim(s)}$path'), headers: {'Content-Type': 'application/json', 'Accept': 'application/json', 'User-Agent': 'KairosNova/$version'}, body: jsonEncode(body))
            .timeout(timeout);
        Map<String, dynamic>? j;
        try {
          final d = jsonDecode(utf8.decode(r.bodyBytes));
          if (d is Map) j = Map<String, dynamic>.from(d);
        } catch (_) {}
        if (j == null) {
          last = PanelException('Il server ha risposto con una pagina non valida (HTTP ${r.statusCode})');
          continue; // rete che blocca il dominio: si prova l'indirizzo di riserva
        }
        if (_trim(s) != _trim(server)) {
          server = _trim(s);
          onServerChanged?.call(server);
        }
        return PanelResponse(r.statusCode, j);
      } on PanelException catch (e) {
        last = e;
      } on Object catch (e) {
        last = PanelException(e.toString().contains('Timeout') ? 'Il server non risponde' : 'Impossibile raggiungere il server');
      }
    }
    throw last ?? const PanelException('Impossibile raggiungere il server');
  }

  Future<PanelState> register() async {
    final r = await _post('/api/player/register', {..._auth(), 'model': model, 'ver': ver});
    final j = r.body!;
    if (r.status == 403 && j['status'] == 'locked') return PanelState.locked;
    if (r.status == 429) throw const PanelException('Troppe richieste: riprovo tra poco');
    if (r.status >= 400) throw PanelException((j['error'] ?? 'Errore del server (HTTP ${r.status})').toString());
    return PanelState.parse(j);
  }

  /// Battito per «Online ora» e per il controllo remoto (impostazioni imposte, comandi, aggiornamento).
  /// [stats]: misure del lettore (bw Mbps, line, dev, stalls10, ttff, fmt, drop) mostrate dal pannello in «Online ora».
  Future<Map<String, dynamic>?> heartbeat({required String state, String title = '', String screen = '', int kickAck = 0, Map<String, Object?> cfg = const {}, Map<String, Object?> stats = const {}, String rcv = ''}) async {
    try {
      final r = await _post('/api/player/heartbeat', {
        ..._auth(),
        'state': state,
        'title': title,
        'ch': '',
        'chId': '',
        'group': '',
        'pl': '',
        'prof': '',
        'ver': ver,
        'ui': '',
        'model': model,
        'screen': screen.length > 20 ? screen.substring(0, 20) : screen,
        'net': {'type': ''},
        'vpn': 'off',
        'cfg': cfg,
        'stats': stats,
        'rcv': rcv,
        if (kickAck > 0) 'kickAck': kickAck,
      });
      return r.status == 200 ? r.body : null;
    } on PanelException {
      return null;
    }
  }

  /// Conferma al pannello di un comando del controllo remoto.
  Future<void> cmdAck(int id, bool ok, String info) async {
    try {
      await _post('/api/player/cmd', {..._auth(), 'id': id, 'ok': ok, 'info': info.length > 200 ? info.substring(0, 200) : info});
    } on PanelException {
      // il pannello lo rimanderà se serve
    }
  }
}
