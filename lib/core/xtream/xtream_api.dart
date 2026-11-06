import 'dart:convert';

import 'package:http/http.dart' as http;

/// Client Xtream Codes API (player_api.php).
/// Usato per: info account/scadenza, categorie, catch-up, dettagli VOD/serie.
/// La lista canali completa viene comunque scaricata via get.php (M3U) e
/// passata al parser in streaming: molto più leggero del JSON da 300k voci.
class XtreamApi {
  XtreamApi({required this.baseUrl, required this.username, required this.password});

  final String baseUrl;
  final String username;
  final String password;

  final _client = http.Client();

  Uri _u(String action, [Map<String, String> extra = const {}]) => Uri.parse(
        '$baseUrl/player_api.php',
      ).replace(queryParameters: {
        'username': username,
        'password': password,
        if (action.isNotEmpty) 'action': action,
        ...extra,
      });

  Future<dynamic> _get(String action, [Map<String, String> extra = const {}]) async {
    final res = await _client
        .get(_u(action, extra), headers: {'User-Agent': 'KairosNova/1.0'})
        .timeout(const Duration(seconds: 25));
    if (res.statusCode != 200) {
      throw Exception('Xtream HTTP ${res.statusCode}');
    }
    return jsonDecode(res.body);
  }

  Future<XtreamAccount> account() async {
    final j = await _get('') as Map<String, dynamic>;
    final ui = j['user_info'] as Map<String, dynamic>? ?? {};
    final si = j['server_info'] as Map<String, dynamic>? ?? {};
    return XtreamAccount(
      status: ui['status']?.toString() ?? 'unknown',
      expiry: _ts(ui['exp_date']),
      maxConnections: int.tryParse('${ui['max_connections'] ?? 0}') ?? 0,
      activeConnections: int.tryParse('${ui['active_cons'] ?? 0}') ?? 0,
      isTrial: ui['is_trial']?.toString() == '1',
      serverTimezone: si['timezone']?.toString(),
    );
  }

  Future<List<XtreamCategory>> categories(String kind) async {
    final j = await _get('get_${kind}_categories') as List;
    return j
        .map((e) => XtreamCategory(
              id: e['category_id'].toString(),
              name: e['category_name'].toString(),
            ))
        .toList();
  }

  Future<Map<String, dynamic>> vodInfo(String vodId) async =>
      (await _get('get_vod_info', {'vod_id': vodId})) as Map<String, dynamic>;

  Future<Map<String, dynamic>> seriesInfo(String seriesId) async =>
      (await _get('get_series_info', {'series_id': seriesId})) as Map<String, dynamic>;

  /// Programmi EPG brevi per un canale (fallback quando non c'è XMLTV).
  Future<List<Map<String, dynamic>>> shortEpg(String streamId, {int limit = 10}) async {
    final j = await _get('get_short_epg', {'stream_id': streamId, 'limit': '$limit'});
    final list = (j as Map<String, dynamic>)['epg_listings'] as List? ?? [];
    return list.cast<Map<String, dynamic>>();
  }

  /// URL catch-up (timeshift) per rivedere un programma già andato in onda.
  String catchupUrl({
    required String streamId,
    required DateTime start,
    required Duration length,
  }) {
    final s = '${start.year}-${_2(start.month)}-${_2(start.day)}:${_2(start.hour)}-${_2(start.minute)}';
    return '$baseUrl/streaming/timeshift.php?username=$username&password=$password'
        '&stream=$streamId&start=$s&duration=${length.inMinutes}';
  }

  String xmltvUrl() => '$baseUrl/xmltv.php?username=$username&password=$password';

  static String _2(int n) => n.toString().padLeft(2, '0');

  static DateTime? _ts(dynamic v) {
    final n = int.tryParse('$v');
    return n == null ? null : DateTime.fromMillisecondsSinceEpoch(n * 1000);
  }

  void dispose() => _client.close();
}

class XtreamAccount {
  const XtreamAccount({
    required this.status,
    this.expiry,
    this.maxConnections = 0,
    this.activeConnections = 0,
    this.isTrial = false,
    this.serverTimezone,
  });
  final String status;
  final DateTime? expiry;
  final int maxConnections;
  final int activeConnections;
  final bool isTrial;
  final String? serverTimezone;

  bool get isActive => status.toLowerCase() == 'active';
  int? get daysLeft => expiry?.difference(DateTime.now()).inDays;
}

class XtreamCategory {
  const XtreamCategory({required this.id, required this.name});
  final String id;
  final String name;
}
